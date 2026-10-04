import Foundation

actor CoachPreferences {
	private let ledger: Ledger
	private let clock: any Clock
	private let diagnostics: DiagnosticsLog
	private let vault: CredentialVault
	private let builtInModel: ModelID
	private var records: [AthleteRecord] = []
	private var loaded = false
	private var reading: Task<Result<[AthleteRecord], LedgerFailure>, Never>?

	init(
		ledger: Ledger, clock: any Clock, diagnostics: DiagnosticsLog, vault: CredentialVault,
		builtInModel: ModelID
	) {
		self.ledger = ledger
		self.clock = clock
		self.diagnostics = diagnostics
		self.vault = vault
		self.builtInModel = builtInModel
	}

	func modelAccess() async throws(AccessUnavailable) -> ResolvedAccess {
		await vault.refreshRejections()
		let target = try await vault.consentTarget(builtInModel: builtInModel)
		guard await consent()?.authorizes(target) == true else {
			throw .providerConsentRequired
		}
		return try await vault.modelAccess(builtInModel: builtInModel)
	}

	func authorizeInvocation(_ invocation: ModelInvocation) async throws(AccessUnavailable) {
		switch invocation {
		case .authorize(let request):
			let target = try await vault.requestTarget(request)
			guard await consent()?.authorizes(target) == true else {
				throw .providerConsentRequired
			}
			try await vault.authorizeInvocation(request)
		case .rejected(let request):
			if let reference = request.credential.openRouterReference {
				try await vault.noteRejected(reference)
			}
		}
	}

	func consent() async -> ProviderConsent? {
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

	func recordConsent(_ target: ConsentTarget) async throws(ConsentWriteFailure) {
		guard await consent()?.authorizes(target) != true else { return }
		let stamp = OperationStamp(
			operation: .preferenceChange(PreferenceChangeID(ulid: await ledger.nextULID())),
			attempt: AttemptID(ulid: await ledger.nextULID()), binding: binding)
		do {
			_ = try await ledger.commit(
				local: [.providerConsent(ProviderConsent(target: target, at: clock.now))],
				stamp: stamp)
		} catch {
			throw .notSaved
		}
	}

	func setLanguage(_ preference: LanguagePreference) async throws(PreferenceWriteFailure) {
		guard await load().language != preference else { return }
		try await commit(.languagePreference(LanguagePreferenceBody(preference: preference)))
	}

	func setSession(_ settings: SessionSettings) async throws(PreferenceWriteFailure) {
		try await commit(.sessionSettings(SessionSettingsBody(settings: settings)))
	}

	private var binding: ActionBinding {
		ActionBinding(account: .unconnected, zone: AthleteCalendar(clock: clock).deviceZone)
	}

	private func commit(_ body: SyncedRecordBody) async throws(PreferenceWriteFailure) {
		_ = await load()
		let stamp = OperationStamp(
			operation: .preferenceChange(PreferenceChangeID(ulid: await ledger.nextULID())),
			attempt: AttemptID(ulid: await ledger.nextULID()), binding: binding)
		let committed: [AthleteRecord]
		do {
			committed = try await ledger.commit(synced: [body], stamp: stamp)
		} catch {
			throw .notSaved
		}
		records += committed
	}

	func load(reload: Bool = false) async -> Preferences {
		guard reload || !loaded else { return Preferences.fold(records) }
		let pending =
			(reload ? nil : reading)
			?? Task { [ledger] in
				do throws(LedgerFailure) {
					return Result<[AthleteRecord], LedgerFailure>.success(
						try await ledger.read(RecordQuery(scope: Preferences.scope)).records)
				} catch {
					return .failure(error)
				}
			}
		reading = pending
		let result = await pending.value
		if reading == pending { reading = nil }
		switch result {
		case .success(let stored):
			records =
				stored + records.filter { written in !stored.contains { $0.ulid == written.ulid } }
			loaded = true
		case .failure(let error):
			diagnostics.record(.preferencesUnavailable(error))
		}
		return Preferences.fold(records)
	}
}
