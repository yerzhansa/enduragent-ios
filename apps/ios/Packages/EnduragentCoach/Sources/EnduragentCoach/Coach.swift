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
	private var mailboxSlots: [ChatID: MailboxSlot] = [:]
	var mailboxes: [ChatID: ChatMailbox] { mailboxSlots.compactMapValues(\.mailbox) }
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
		let mailbox: ChatMailbox
		do {
			mailbox = try await self.mailbox(for: chat)
		} catch {
			return .storageUnavailable
		}
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

	func snapshotFeed(for chat: ChatID) -> SnapshotFeed {
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
