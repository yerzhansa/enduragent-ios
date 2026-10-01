import Foundation

public actor Coach {
	package let memory: Memory
	public nonisolated let credits: any CreditsClient
	package nonisolated let diagnostics: DiagnosticsLog

	private let sport: SportID
	private let transport: any ModelTransport
	let ledger: Ledger
	private let clock: any Clock
	private let coalescing: CoalescingPolicy
	private let coalescingSleep: @Sendable (Duration) async throws -> Void
	private let host: any ExecutionHost
	private let deviceLanguage: LanguageTag
	private var preferenceRecords: [AthleteRecord] = []
	private var preferencesLoaded = false
	private var preferencesRead: Task<Result<[AthleteRecord], LedgerFailure>, Never>?
	private let builtInModel: ModelID
	private let vault: CredentialVault
	private let runner: TurnRunner
	private let reviews: SingleProposalReviews
	var mailboxes: [ChatID: ChatMailbox]
	let lifetime = Lifetime()
	private var recovery: Task<Bool, Never>?
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

	public func history() async throws(HistoryUnavailable) -> [ArchivedConversationSummary] {
		do {
			return try await ledger.history()
		} catch {
			throw .storageUnavailable
		}
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
	}

	public func decide(_ decision: ReviewDecision, in chat: ChatID) async -> ReviewOutcome {
		let mailbox = await mailbox(for: chat)
		let outcome = await reviews.decide(
			decision, chat: chat, scope: await mailbox.reviewScope)
		await mailbox.reviewChanged()
		return outcome
	}

	public func languagePreference() async -> LanguagePreference {
		await loadedPreferences().language
	}

	public func status() async -> CoachStatus {
		let consent = await providerConsent()
		return CoachStatus(
			setup: consent?.isCurrent == true
				? await vault.setup(builtInModel: builtInModel) : .needsProviderConsent,
			training: await vault.trainingStatus(), preferences: await loadedPreferences(),
			providerConsent: consent)
	}

	public func recordConsent() async throws(PreferenceWriteFailure) {
		guard await providerConsent()?.isCurrent != true else { return }
		let stamp = OperationStamp(
			operation: .preferenceChange(PreferenceChangeID(ulid: await ledger.nextULID())),
			attempt: AttemptID(ulid: await ledger.nextULID()), binding: binding)
		do {
			_ = try await ledger.commit(
				local: [.providerConsent(ProviderConsent(at: clock.now))], stamp: stamp)
		} catch {
			throw .notSaved
		}
	}

	private func providerConsent() async -> ProviderConsent? {
		do {
			let page = try await ledger.read(
				RecordQuery(scope: .deviceLocal([.providerConsent]), writtenBy: ledger.deviceId))
			guard case .deviceLocal(.providerConsent(let consent)) = page.records.last?.body
			else { return nil }
			return consent
		} catch {
			diagnostics.record(.preferencesUnavailable(error))
			return nil
		}
	}

	private func modelAccess() async throws(AccessUnavailable) -> ResolvedAccess {
		guard await providerConsent()?.isCurrent == true else {
			throw .providerConsentRequired
		}
		return try await vault.modelAccess(builtInModel: builtInModel)
	}

	public func setLanguage(_ preference: LanguagePreference) async throws(PreferenceWriteFailure) {
		guard await loadedPreferences().language != preference else { return }
		try await commitPreference(
			.languagePreference(LanguagePreferenceBody(preference: preference)))
	}

	public func setSession(_ settings: SessionSettings) async throws(PreferenceWriteFailure) {
		try await commitPreference(.sessionSettings(SessionSettingsBody(settings: settings)))
	}

	public func changeTraining(_ change: IntervalsConnectionChange) async
		-> CredentialOutcome<IntervalsSummary>
	{
		let clock = self.clock
		let outcome = await vault.change(change) { await self.holdsBoundWork(now: clock.now) }
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

	private var binding: ActionBinding {
		ActionBinding(account: .unconnected, zone: AthleteCalendar(clock: clock).deviceZone)
	}

	private func commitPreference(_ body: SyncedRecordBody) async throws(PreferenceWriteFailure) {
		_ = await loadedPreferences()
		let stamp = OperationStamp(
			operation: .preferenceChange(PreferenceChangeID(ulid: await ledger.nextULID())),
			attempt: AttemptID(ulid: await ledger.nextULID()),
			binding: binding
		)
		let committed: [AthleteRecord]
		do {
			committed = try await ledger.commit(synced: [body], stamp: stamp)
		} catch {
			throw .notSaved
		}
		preferenceRecords += committed
	}

	private func loadedPreferences() async -> Preferences {
		guard !preferencesLoaded else { return Preferences.fold(preferenceRecords) }
		let reading = preferencesRead ?? Task { await self.readPreferences() }
		preferencesRead = reading
		let result = await reading.value
		if preferencesRead == reading {
			preferencesRead = nil
		}
		switch result {
		case .success(let stored) where !preferencesLoaded:
			preferenceRecords =
				stored
				+ preferenceRecords.filter { written in
					!stored.contains { $0.ulid == written.ulid }
				}
			preferencesLoaded = true
		case .success:
			break
		case .failure(let error):
			diagnostics.record(.preferencesUnavailable(error))
		}
		return Preferences.fold(preferenceRecords)
	}

	private func readPreferences() async -> Result<[AthleteRecord], LedgerFailure> {
		do {
			return .success(try await ledger.read(RecordQuery(scope: Preferences.scope)).records)
		} catch {
			return .failure(error)
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
			coalescingSleep: coalescingSleep,
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
