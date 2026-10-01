import Foundation

public actor Coach {
	package let memory: Memory
	public nonisolated let credits: any CreditsClient
	package nonisolated let diagnostics: DiagnosticsLog

	private let sport: SportID
	private let transport: any ModelTransport
	let ledger: Ledger
	let clock: any Clock
	private let coalescing: CoalescingPolicy
	private let host: any ExecutionHost
	private let deviceLanguage: LanguageTag
	var preferenceRecords: [AthleteRecord] = []
	var preferencesLoaded = false
	var preferencesRead: Task<Result<[AthleteRecord], LedgerFailure>, Never>?
	let builtInModel: ModelID
	let vault: CredentialVault
	private let runner: TurnRunner
	private let reviews: SingleProposalReviews
	var mailboxes: [ChatID: ChatMailbox]
	let lifetime = Lifetime()
	private var recovery: Task<Bool, Never>?
	let statusFeed = SnapshotFeed<CoachStatus>()
	let statusChanges = Turnstile()
	var trainingStatus: TrainingStatus?
	var trainingRefresh: Task<TrainingStatus, Never>?
	var importObservation: Task<Void, Never>?
	var pendingImportRefresh: Task<Void, Never>?
	private let process: ProcessID

	deinit {
		importObservation?.cancel()
		pendingImportRefresh?.cancel()
	}

	public init(
		sport: SportID,
		ports: CoachPorts,
		builtInModel: ModelID,
		deviceLanguage: LanguageTag,
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
		let ledger = Ledger(log: ports.records.log, clock: clock, diagnostics: diagnostics)
		self.ledger = ledger
		self.clock = clock
		self.coalescing = coalescing
		self.host = ports.host
		self.deviceLanguage = deviceLanguage
		self.memory = Memory(ledger: ledger, clock: clock)
		self.runner = TurnRunner(
			transport: transport,
			ledger: ledger,
			clock: clock,
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
		await mailbox(for: chat).interrupt(.athleteStopped)
	}

	public func startNewConversation(in chat: ChatID) async -> ResetOutcome {
		await mailbox(for: chat).reset()
	}

	public func history() async throws(HistoryUnavailable) -> [ArchivedConversation] {
		do {
			return try await ledger.archivedConversations(
				process: process, today: CivilDate(date: clock.now, timeZone: clock.timeZone))
		} catch {
			throw .storageUnavailable
		}
	}

	public func lifecycle(_ event: AppLifecycleEvent) async {
		switch event {
		case .becameActive:
			await recoverOnce()
		case .willResignActive:
			return
		case .willTerminate:
			lifetime.terminate()
			importObservation?.cancel()
			importObservation = nil
			pendingImportRefresh?.cancel()
			pendingImportRefresh = nil
		case .enteredBackground:
			break
		}
		for mailbox in mailboxes.values {
			await mailbox.lifecycle(event)
		}
		if event == .becameActive {
			await refreshTrainingStatus()
		}
	}

	public func decide(_ decision: ReviewDecision, in chat: ChatID) async -> ReviewOutcome {
		let mailbox = await mailbox(for: chat)
		let outcome = await reviews.decide(
			decision, chat: chat, scope: await mailbox.reviewScope)
		await mailbox.reviewChanged()
		return outcome
	}

	private func modelAccess() async throws(AccessUnavailable) -> ResolvedAccess {
		guard await providerConsent()?.isCurrent == true else {
			throw .providerConsentRequired
		}
		return try await vault.modelAccess(builtInModel: builtInModel)
	}

	public func changeTraining(_ change: IntervalsConnectionChange) async
		-> CredentialOutcome<IntervalsSummary>
	{
		let outcome = await vault.change(change) { await self.holdsBoundWork() }
		trainingRefresh?.cancel()
		trainingRefresh = nil
		trainingStatus = nil
		for mailbox in mailboxes.values {
			await mailbox.reviewChanged()
		}
		if statusFeed.isObserved {
			await refreshTrainingStatus()
		}
		return outcome
	}

	public func changeModelAccess(_ change: ModelAccessChange) async
		-> CredentialOutcome<AccessSummary>
	{
		let outcome = await vault.change(change)
		await publishStatus()
		return outcome
	}

	public func creditsIdentity() async throws(AccessUnavailable) -> CreditsIdentity {
		try await vault.creditsIdentity()
	}

	public func prepareCreditsPurchase() async throws(AccessUnavailable) -> UUID {
		try await vault.prepareCreditsAccount()
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

	#if DEBUG
		public nonisolated func recordSyncProbe() -> RecordSyncProbe {
			RecordSyncProbe(ledger: ledger, clock: clock)
		}
	#endif

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
		let local = try await ledger.read(
			RecordQuery(scope: TurnRecovery.localScope, writtenBy: device)
		).records
		let chats = Set(local.compactMap(\.chatId))
		guard !chats.isEmpty else { return [:] }
		let synced = try await ledger.read(RecordQuery(scope: ConversationFold.syncedScope)).records
		let conversations = Dictionary(
			uniqueKeysWithValues: chats.map { chat in
				(
					chat,
					ConversationFold.fold(chat: chat, synced: synced, local: local, device: device)
				)
			})
		let flushQueue = try await ledger.flushJobsByChat(in: conversations, local: local)
		let turns = conversations.mapValues { $0.segments.flatMap(\.turns) }
		let dead = Set(
			turns.values.flatMap {
				TurnRecovery.plan(turns: $0, writes: [:], device: device, process: process)
					.interrupt.map(\.attempt)
			})
		var writes: [AttemptID: WriteSummary] = [:]
		if !dead.isEmpty {
			let stamped = try await ledger.read(
				RecordQuery(scope: TurnRecovery.stampedWrites, writtenBy: device)
			).records
			writes = TurnRecovery.writes(of: dead, in: stamped)
		}
		var plans: [ChatID: RecoveryPlan] = [:]
		for (chat, conversation) in conversations {
			let drain = FlushJob.outstanding(
				flushQueue[chat] ?? [], in: conversation)
			let plan = TurnRecovery.plan(
				turns: turns[chat] ?? [], drain: drain.map(\.id), writes: writes,
				device: device, process: process)
			if !plan.isEmpty {
				plans[chat] = plan
			}
		}
		return plans
	}

	func mailbox(for chatId: ChatID) async -> ChatMailbox {
		await recoverOnce()
		return makeMailbox(for: chatId)
	}

	private func makeMailbox(for chatId: ChatID) -> ChatMailbox {
		observeImports()
		if let existing = mailboxes[chatId] {
			return existing
		}
		let vault = self.vault
		let access: @Sendable () async throws(AccessUnavailable) -> ResolvedAccess = {
			() async throws(AccessUnavailable) in
			try await self.modelAccess()
		}
		let created = ChatMailbox(
			chatId: chatId,
			ledger: ledger,
			runner: runner,
			flushes: FlushWork(
				chat: chatId, process: process, ledger: ledger, memory: memory,
				transport: transport, clock: clock,
				diagnostics: diagnostics, ladder: runner.ladder),
			clock: clock,
			coalescing: coalescing,
			environment: EnvironmentResolver(
				preferences: { await self.loadedPreferences() }, access: access,
				training: { () async throws(AccessUnavailable) in
					try await vault.trainingConnection()
				}, deviceLanguage: deviceLanguage),
			reviews: reviews,
			process: process,
			host: host,
			lifetime: lifetime
		)
		mailboxes[chatId] = created
		return created
	}

}
