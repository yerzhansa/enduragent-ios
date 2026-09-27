import Foundation

public actor Coach {
	public let memory: Memory
	public let planning: Planning
	public nonisolated let credits: any CreditsClient
	package nonisolated let diagnostics: DiagnosticsLog

	private let sport: SportID
	private let transport: any ModelTransport
	private let ledger: Ledger
	private let clock: any Clock
	private let coalescing: CoalescingPolicy
	private var language: LanguagePreference
	private let builtInModel: ModelID
	private let vault: CredentialVault
	private let runner: TurnRunner
	private let reviews: SingleProposalReviews
	private var mailboxes: [ChatID: ChatMailbox]
	private var recovery: Task<Bool, Never>?
	private let process: ProcessID

	public init(
		sport: SportID,
		ports: CoachPorts,
		builtInModel: ModelID,
		language: LanguagePreference,
		coalescing: CoalescingPolicy = .npm
	) {
		let clock = ports.clock
		let diagnostics = DiagnosticsLog(clock: clock)
		let transport = ports.models.makeTransport(diagnostics)
		let vault = CredentialVault(
			store: ports.secrets, training: ports.training, clock: clock, diagnostics: diagnostics)
		self.diagnostics = diagnostics
		self.sport = sport
		self.transport = transport
		self.vault = vault
		self.credits = ports.credits.makeClient(vault)
		self.builtInModel = builtInModel
		let ledger = Ledger(log: ports.records, clock: clock, diagnostics: diagnostics)
		self.ledger = ledger
		self.clock = clock
		self.coalescing = coalescing
		self.language = language
		self.memory = Memory(ledger: ledger, clock: clock)
		let planning = Planning(store: ports.records, clock: clock)
		self.planning = planning
		self.runner = TurnRunner(
			transport: transport,
			ledger: ledger,
			clock: clock,
			planning: planning,
			diagnostics: diagnostics,
			ladder: .npm,
			evidence: WellnessEvidence(clock: clock, diagnostics: diagnostics)
		)
		self.reviews = SingleProposalReviews(
			ledger: ledger, clock: clock, diagnostics: diagnostics,
			training: { () async throws(AccessUnavailable) in try await vault.trainingConnection() }
		)
		self.mailboxes = [:]
		self.process = ProcessID(ulid: ULID.generate(at: clock.now))
	}

	public func observe(_ chat: ChatID) async -> AsyncStream<ChatSnapshot> {
		await mailbox(for: chat).observe()
	}

	public func send(_ draft: Draft, to chat: ChatID) async throws(AcceptFailure) -> SendOutcome {
		try await mailbox(for: chat).accept(draft)
	}

	public func retry(_ turn: TurnID, in chat: ChatID) async throws(RetryRefusal) {
		try await mailbox(for: chat).retry(turn)
	}

	public func stop(_ chat: ChatID) async {
		await mailbox(for: chat).stop()
	}

	public func lifecycle(_ event: AppLifecycleEvent) async {
		switch event {
		case .becameActive:
			await recoverOnce()
		case .willResignActive:
			return
		case .enteredBackground, .willTerminate:
			for mailbox in mailboxes.values {
				await mailbox.lifecycle(event)
			}
		}
	}

	public func decide(_ decision: ReviewDecision, in chat: ChatID) async -> ReviewOutcome {
		let outcome = await reviews.decide(decision, chat: chat)
		await mailbox(for: chat).reviewChanged()
		return outcome
	}

	public func status() async -> CoachStatus {
		CoachStatus(
			setup: await vault.setup(builtInModel: builtInModel),
			training: await vault.trainingStatus())
	}

	public func changeTraining(_ change: IntervalsConnectionChange) async
		-> CredentialOutcome<IntervalsSummary>
	{
		let outcome = await vault.change(change) { await self.holdsBoundWork() }
		for mailbox in mailboxes.values {
			await mailbox.reviewChanged()
		}
		return outcome
	}

	public func changeModelAccess(_ change: ModelAccessChange) async
		-> CredentialOutcome<AccessSummary>
	{
		await vault.change(change)
	}

	public func creditsIdentity() async throws(AccessUnavailable) -> CreditsIdentity {
		try await vault.creditsIdentity()
	}

	#if DEBUG
		public func replaceAppAccountToken() async throws(AccessUnavailable) {
			try await vault.replaceAppAccountToken()
		}
	#endif

	private func holdsBoundWork() async -> Bool {
		for mailbox in mailboxes.values {
			var snapshots = await mailbox.observe().makeAsyncIterator()
			guard let snapshot = await snapshots.next() else { continue }
			if snapshot.review != nil
				|| snapshot.turns.contains(where: { !$0.state.isSettled })
			{
				return true
			}
		}
		return false
	}

	public func setCoachReplyLanguage(_ tag: LanguageTag?) async throws {
		let stamp = OperationStamp(
			operation: .preferenceChange(PreferenceChangeID(ulid: await ledger.nextULID())),
			attempt: AttemptID(ulid: await ledger.nextULID()),
			binding: binding
		)
		_ = try await ledger.commit(
			synced: [.coachReplyLanguage(CoachReplyLanguageBody(tag: tag))], stamp: stamp)
		language.coachReply = tag
	}

	#if DEBUG
		public nonisolated func recordSyncProbe() -> RecordSyncProbe {
			RecordSyncProbe(ledger: ledger, clock: clock)
		}
	#endif

	private var binding: ActionBinding {
		ActionBinding(account: .unconnected, zone: AthleteCalendar(clock: clock).deviceZone)
	}

	public func waitForMemoryFlush() async {
		for box in mailboxes.values {
			await box.flushAndDrain()
		}
	}

	private func recoverOnce() async {
		let recovering = recovery ?? Task { await self.recoverDeadClaims() }
		recovery = recovering
		if await !recovering.value, recovery == recovering {
			recovery = nil
		}
	}

	private func recoverDeadClaims() async -> Bool {
		do {
			for (chat, plan) in try await recoveryPlans() {
				try await makeMailbox(for: chat).recover(plan)
			}
			return true
		} catch {
			diagnostics.record(.recoveryUnavailable(error))
			return false
		}
	}

	private func recoveryPlans() async throws(LedgerFailure) -> [ChatID: RecoveryPlan] {
		let device = ledger.deviceId
		let claims = try await ledger.read(
			RecordQuery(scope: TurnRecovery.claimScope, writtenBy: device)
		).records
		let chats = Set(claims.compactMap(\.chatId))
		guard !chats.isEmpty else { return [:] }
		let synced = try await ledger.read(
			RecordQuery(scope: TurnRecovery.turnScope, writtenBy: device)
		).records
		var turns: [ChatID: [TurnFacts]] = [:]
		for chat in chats {
			turns[chat] = ConversationFold.fold(
				chat: chat, synced: synced, local: claims, device: device
			).segments.flatMap(\.turns)
		}
		let dead = Set(
			turns.values.flatMap {
				TurnRecovery.plan(turns: $0, writes: [:], device: device, process: process)
					.interrupt.map(\.attempt)
			})
		guard !dead.isEmpty else { return [:] }
		let stamped = try await ledger.read(
			RecordQuery(scope: TurnRecovery.stampedWrites, writtenBy: device)
		).records
		let writes = TurnRecovery.writes(of: dead, in: stamped)
		return turns.mapValues {
			TurnRecovery.plan(turns: $0, writes: writes, device: device, process: process)
		}.filter { !$0.value.interrupt.isEmpty }
	}

	private func mailbox(for chatId: ChatID) async -> ChatMailbox {
		await recoverOnce()
		return makeMailbox(for: chatId)
	}

	private func makeMailbox(for chatId: ChatID) -> ChatMailbox {
		if let existing = mailboxes[chatId] {
			return existing
		}
		let vault = self.vault
		let builtInModel = self.builtInModel
		let access: @Sendable () async throws(AccessUnavailable) -> ResolvedAccess = {
			() async throws(AccessUnavailable) in
			try await vault.modelAccess(builtInModel: builtInModel)
		}
		let created = ChatMailbox(
			chatId: chatId,
			ledger: ledger,
			runner: runner,
			flushes: FlushDrain(
				memory: memory, transport: transport, access: access, diagnostics: diagnostics),
			clock: clock,
			coalescing: coalescing,
			environment: EnvironmentResolver(
				language: { await self.language }, access: access,
				training: { () async throws(AccessUnavailable) in
					try await vault.trainingConnection()
				}),
			reviews: reviews,
			process: process
		)
		mailboxes[chatId] = created
		return created
	}
}
