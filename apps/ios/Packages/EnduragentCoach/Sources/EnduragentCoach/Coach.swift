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
	private let coalescingSleep: @Sendable (Duration) async throws -> Void
	private let host: any ExecutionHost
	private let deviceLanguage: LanguageTag
	var preferenceRecords: [AthleteRecord] = []
	var preferencesLoaded = false
	var preferencesRead: Task<Result<[AthleteRecord], LedgerFailure>, Never>?
	let builtInModel: ModelID
	let vault: CredentialVault
	private let runner: TurnRunner
	private let reviews: SingleProposalReviews
	private var mailboxSlots: [ChatID: MailboxSlot] = [:]
	var mailboxes: [ChatID: ChatMailbox] { mailboxSlots.compactMapValues(\.mailbox) }
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
		self.coalescingSleep = ports.coalescingSleep
		self.host = ports.host
		self.deviceLanguage = deviceLanguage
		self.memory = Memory(ledger: ledger, clock: clock, watchdogSleep: ports.watchdogSleep)
		self.runner = TurnRunner(
			transport: transport, ledger: ledger, clock: clock,
			diagnostics: diagnostics, ladder: .npm,
			evidence: WellnessEvidence(clock: clock, diagnostics: diagnostics),
			watchdogSleep: ports.watchdogSleep)
		self.reviews = SingleProposalReviews(
			ledger: ledger, clock: clock, diagnostics: diagnostics,
			training: { () async throws(AccessUnavailable) in try await vault.trainingConnection() }
		)
		self.process = ProcessID(ulid: ULID.generate(at: clock.now))
	}

	public func archivedConversation(_ ref: ArchivedConversationRef)
		async throws(HistoryUnavailable) -> ArchivedConversation?
	{
		do {
			return try await ledger.archivedConversation(
				ref, process: process, today: CivilDate(date: clock.now, timeZone: clock.timeZone))
		} catch {
			throw .storageUnavailable
		}
	}

	public func lifecycle(_ event: AppLifecycleEvent) async {
		lifetime.apply(event)
		switch event {
		case .becameActive:
			await recoverOnce()
		case .willTerminate:
			importObservation?.cancel()
			importObservation = nil
			pendingImportRefresh?.cancel()
			pendingImportRefresh = nil
			for mailbox in mailboxes.values {
				await mailbox.cancelInFlight(cause: .appTerminating)
			}
		case .enteredBackground:
			for mailbox in mailboxes.values {
				await mailbox.enteredBackground()
			}
		}
		if event == .becameActive {
			await refreshTrainingStatus()
		}
	}

	public func decide(_ decision: ReviewDecision, in chat: ChatID) async -> ReviewOutcome {
		let mailbox: ChatMailbox
		do {
			mailbox = try await self.mailbox(for: chat)
		} catch {
			return .storageUnavailable
		}
		if case .checkAgain(let ref) = decision {
			return await mailbox.reviewChanged(ref)
		}
		let outcome = await reviews.decide(
			decision, chat: chat, scope: await mailbox.reviewScope)
		_ = await mailbox.reviewChanged()
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
		let clock = self.clock
		let outcome = await vault.change(change) { await self.holdsBoundWork(now: clock.now) }
		trainingRefresh?.cancel()
		trainingRefresh = nil
		trainingStatus = nil
		for mailbox in mailboxes.values {
			_ = await mailbox.reviewChanged()
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
				await mailboxes[chat]?.recover(plan)
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
		var conversations: [ChatID: Conversation] = [:]
		var flushQueue: [ChatID: [FlushJob]] = [:]
		for chat in chats {
			let mailbox = try await makeMailbox(for: chat, recoveryRecords: local)
			conversations[chat] = await mailbox.conversation
			flushQueue[chat] = await mailbox.jobs
		}
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
		return TurnRecovery.plans(
			in: conversations, jobs: flushQueue, writes: writes, device: device, process: process)
	}

	func mailbox(for chatId: ChatID) async throws(LedgerFailure) -> ChatMailbox {
		await recoverOnce()
		return try await makeMailbox(for: chatId)
	}

	func snapshotFeed(for chat: ChatID) -> SnapshotFeed<ChatSnapshot> {
		if let slot = mailboxSlots[chat] { return slot.feed }
		let slot = MailboxSlot()
		mailboxSlots[chat] = slot
		return slot.feed
	}

	func openedMailboxes() async -> [ChatMailbox] {
		for (chat, slot) in mailboxSlots {
			guard let opening = slot.opening else { continue }
			if case .failure(let error) = await opening.value {
				diagnostics.record(.importsUnavailable(chat, error))
			}
		}
		return Array(mailboxes.values)
	}

	private func makeMailbox(for chatId: ChatID, recoveryRecords: [AthleteRecord]? = nil)
		async throws(LedgerFailure) -> ChatMailbox
	{
		observeImports()
		if let existing = mailboxSlots[chatId]?.mailbox { return existing }
		_ = snapshotFeed(for: chatId)
		let opening =
			mailboxSlots[chatId]?.opening
			?? Task { await self.openMailbox(for: chatId, recoveryRecords: recoveryRecords) }
		mailboxSlots[chatId]?.opening = opening
		let result = await opening.value
		if mailboxSlots[chatId]?.opening == opening { mailboxSlots[chatId]?.opening = nil }
		return try result.get()
	}

	private func openMailbox(for chatId: ChatID, recoveryRecords: [AthleteRecord]?) async
		-> Result<ChatMailbox, LedgerFailure>
	{
		do {
			let vault = self.vault
			let access: @Sendable () async throws(AccessUnavailable) -> ResolvedAccess = {
				() async throws(AccessUnavailable) in
				try await self.modelAccess()
			}
			let created = try await ChatMailbox.open(
				chatId: chatId,
				ledger: ledger,
				runner: runner,
				flushes: FlushWork(
					chat: chatId, process: process, ledger: ledger, memory: memory,
					transport: transport, clock: clock,
					diagnostics: diagnostics, ladder: runner.ladder),
				clock: clock,
				coalescing: coalescing,
				coalescingSleep: coalescingSleep,
				environment: EnvironmentResolver(
					preferences: { await self.loadedPreferences() }, access: access,
					training: { () async throws(AccessUnavailable) in
						try await vault.trainingConnection()
					}, deviceLanguage: deviceLanguage),
				reviews: reviews,
				process: process,
				host: host,
				lifetime: lifetime, feed: snapshotFeed(for: chatId),
				recoveryRecords: recoveryRecords
			)
			mailboxSlots[chatId]?.mailbox = created
			return .success(created)
		} catch {
			return .failure(error)
		}
	}
}
