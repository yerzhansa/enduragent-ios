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
	private var mailboxes: [ChatID: ChatMailbox]

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
			ladder: .npm
		)
		self.mailboxes = [:]
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

	public func pendingProposal(chatId: ChatID) async -> PendingProposal? {
		let records = (try? await ledger.read(ProposalPolicy.proposalQuery(chatId)).records) ?? []
		return ProposalPolicy.pending(in: records, chatId: chatId, now: clock.now)
	}

	public func confirm(chatId: ChatID, nonce: Nonce) async throws -> ConfirmOutcome {
		_ = sport
		_ = transport
		defer {
			Task { await self.mailbox(for: chatId).refreshProposal() }
		}
		do {
			let training = try await vault.trainingConnection()
			let tools = ToolRuntime(
				intervals: training.client, ledger: ledger, planning: planning, clock: clock)
			let lookup = try await ProposalPolicy.take(
				chatId: chatId,
				nonce: nonce,
				ledger: ledger,
				binding: ActionBinding(
					account: training.account, zone: AthleteCalendar(clock: clock).deviceZone),
				now: clock.now,
				run: { input in
					try await tools.rebuildConfirmed(input)
				}
			)
			switch lookup {
			case .found(let body):
				return .executed(summary: body.summary)
			case .expired:
				return .expired
			case .mismatch:
				return .mismatch
			case .none:
				return .none
			}
		} catch let error as IntervalsError {
			return .refused(message: error.details)
		} catch let error as InvalidWorkout {
			return .refused(message: error.message)
		} catch {
			return .failed(message: "\(error)")
		}
	}

	public func status() async -> CoachStatus {
		CoachStatus(
			setup: await vault.setup(builtInModel: builtInModel),
			training: await vault.trainingStatus())
	}

	public func changeTraining(_ change: IntervalsConnectionChange) async
		-> CredentialOutcome<IntervalsSummary>
	{
		await vault.change(change) { await self.holdsBoundWork() }
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
			if snapshot.pendingProposal != nil
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

	private func mailbox(for chatId: ChatID) -> ChatMailbox {
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
				})
		)
		mailboxes[chatId] = created
		return created
	}
}
