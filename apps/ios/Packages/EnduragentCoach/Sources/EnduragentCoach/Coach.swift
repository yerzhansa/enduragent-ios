import Foundation
import Security

public actor Coach {
	public let memory: Memory
	public let planning: Planning
	package nonisolated let diagnostics: DiagnosticsLog

	private let sport: SportID
	private let transport: any ModelTransport
	private let intervals: any IntervalsClient
	private let ledger: Ledger
	private let clock: any Clock
	private let coalescing: CoalescingPolicy
	private let host: any ExecutionHost
	private var language: LanguagePreference
	private let access: @Sendable () throws(AccessUnavailable) -> ResolvedAccess
	private let tools: ToolRuntime
	private let runner: TurnRunner
	private var mailboxes: [ChatID: ChatMailbox]
	private var recovery: Task<Bool, Never>?
	private let process: ProcessID

	public init(
		sport: SportID,
		models: ModelService,
		builtInModel: ModelID,
		secrets: any SecretStore,
		intervals: any IntervalsClient,
		store: any RecordLog,
		clock: any Clock,
		language: LanguagePreference,
		host: any ExecutionHost,
		coalescing: CoalescingPolicy = .npm
	) {
		let diagnostics = DiagnosticsLog(clock: clock)
		let transport = models.makeTransport(diagnostics)
		self.diagnostics = diagnostics
		self.sport = sport
		self.transport = transport
		self.intervals = intervals
		self.access = { () throws(AccessUnavailable) in
			try Coach.creditsAccess(secrets: secrets, model: builtInModel)
		}
		let ledger = Ledger(log: store, clock: clock, diagnostics: diagnostics)
		self.ledger = ledger
		self.clock = clock
		self.coalescing = coalescing
		self.host = host
		self.language = language
		self.memory = Memory(ledger: ledger, clock: clock)
		let planning = Planning(store: store, intervals: intervals, clock: clock)
		self.planning = planning
		let tools = ToolRuntime(
			intervals: intervals, ledger: ledger, planning: planning, clock: clock)
		self.tools = tools
		self.runner = TurnRunner(
			transport: transport,
			intervals: intervals,
			ledger: ledger,
			clock: clock,
			tools: tools,
			planning: planning,
			diagnostics: diagnostics,
			ladder: .npm
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

	public func lifecycle(_ event: AppLifecycleEvent) async {
		switch event {
		case .becameActive:
			await recoverOnce()
		case .willResignActive:
			return
		case .enteredBackground, .willTerminate:
			break
		}
		for mailbox in mailboxes.values {
			await mailbox.lifecycle(event)
		}
	}

	public func pendingProposal(chatId: ChatID) async -> PendingProposal? {
		let records = (try? await ledger.read(ProposalPolicy.proposalQuery(chatId)).records) ?? []
		return UnionMerge.pendingProposal(records, chatId: chatId, now: clock.now)
			.map(PendingProposal.init)
	}

	public func confirm(chatId: ChatID, nonce: Nonce) async throws -> ConfirmOutcome {
		_ = sport
		_ = transport
		_ = intervals
		let tools = self.tools
		defer {
			Task { await self.mailbox(for: chatId).refreshProposal() }
		}
		do {
			let lookup = try await ProposalPolicy.take(
				chatId: chatId,
				nonce: nonce,
				ledger: ledger,
				binding: binding,
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

	private static func creditsAccess(secrets: any SecretStore, model: ModelID)
		throws(AccessUnavailable) -> ResolvedAccess
	{
		let stored: String?
		do {
			stored = try secrets.openRouterKey()
		} catch let keychain as KeychainStoreError
			where keychain.status == errSecInteractionNotAllowed
		{
			throw .secureStorageLocked
		} catch {
			throw .secureStorageUnavailable
		}
		let secret = stored?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
		guard !secret.isEmpty else {
			throw .notConfigured(.credits)
		}
		return ResolvedAccess(
			credential: ProviderCredential(secret: secret, method: .credits), model: model)
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
		let flushQueue = try await ledger.flushJobsByChat()
		let turns = try await claimedTurns(claims, device: device)
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
		for chat in Set(turns.keys).union(flushQueue.keys) {
			let plan = TurnRecovery.plan(
				turns: turns[chat] ?? [], flushQueue: flushQueue[chat] ?? [], writes: writes,
				device: device, process: process)
			if !plan.isEmpty {
				plans[chat] = plan
			}
		}
		return plans
	}

	private func claimedTurns(_ claims: [AthleteRecord], device: DeviceID)
		async throws(LedgerFailure) -> [ChatID: [TurnFacts]]
	{
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
		return turns
	}

	private func mailbox(for chatId: ChatID) async -> ChatMailbox {
		await recoverOnce()
		return makeMailbox(for: chatId)
	}

	private func makeMailbox(for chatId: ChatID) -> ChatMailbox {
		if let existing = mailboxes[chatId] {
			return existing
		}
		let created = ChatMailbox(
			chatId: chatId,
			ledger: ledger,
			runner: runner,
			flushes: FlushWork(
				chat: chatId, ledger: ledger, memory: memory, transport: transport, clock: clock,
				diagnostics: diagnostics),
			clock: clock,
			coalescing: coalescing,
			environment: EnvironmentResolver(language: { await self.language }, access: access),
			process: process,
			host: host
		)
		mailboxes[chatId] = created
		return created
	}
}
