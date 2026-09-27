import Foundation
import Security

package actor CredentialVault {
	private let store: any SecretStore
	private let training: TrainingService
	private let clock: any Clock
	private let diagnostics: DiagnosticsLog
	private let changes = Admission()
	private var stagingRecovered = false

	package init(
		store: any SecretStore, training: TrainingService, clock: any Clock,
		diagnostics: DiagnosticsLog
	) {
		self.store = store
		self.training = training
		self.clock = clock
		self.diagnostics = diagnostics
	}

	package func modelAccess(builtInModel: ModelID) throws(AccessUnavailable) -> ResolvedAccess {
		recoverStaging()
		switch try keychain(.accessSelection, { try store.accessSelection() }) {
		case nil, .credits?:
			return try resolve(.creditsKey, .credits, builtInModel) { try store.openRouterKey() }
		case .openRouterAccount(let model, _)?:
			return try resolve(.openRouterAccountKey, .openRouterAccount, model) {
				try store.openRouterAccountKey()
			}
		}
	}

	package func trainingConnection() throws(AccessUnavailable) -> TrainingConnection {
		recoverStaging()
		guard let active = try activeConnection() else { return .unconnected }
		return TrainingConnection(
			account: active.account,
			client: client(for: active.connection))
	}

	package func setup(builtInModel: ModelID) -> SetupState {
		do {
			_ = try modelAccess(builtInModel: builtInModel)
			return .ready
		} catch .notConfigured {
			return .needsAccessMethod
		} catch {
			return .accessTemporarilyUnavailable(error)
		}
	}

	package func trainingStatus() async -> TrainingStatus {
		recoverStaging()
		let active: ActiveConnection?
		do {
			active = try activeConnection()
		} catch {
			return .unavailable(error)
		}
		guard let active else { return .unconnected }
		let read = await self.read(active)
		return .connected(read.summary, account: read.active.account)
	}

	package func change(
		_ change: IntervalsConnectionChange, boundWork: @Sendable () async -> Bool
	) async -> CredentialOutcome<IntervalsSummary> {
		await changes.pass { _ in await applying(change, boundWork: boundWork) }
	}

	private func applying(
		_ change: IntervalsConnectionChange, boundWork: @Sendable () async -> Bool
	) async -> CredentialOutcome<IntervalsSummary> {
		recoverStaging()
		let current: ActiveConnection?
		do {
			current = try activeConnection()
		} catch {
			return .failedPreviousKept(.secureStorage(error), previous: nil)
		}
		switch change {
		case .keep:
			return .kept(await summary(ofCurrent: current))
		case .disconnect:
			do {
				try keychain(.intervalsConnection) { try store.delete(.intervalsConnection) }
			} catch {
				return .failedPreviousKept(
					.secureStorage(error), previous: await summary(ofCurrent: current))
			}
			return .disconnected
		case .replace(let apiKey, let athlete):
			return await replace(apiKey, athlete, over: current, switching: false, boundWork)
		case .replaceConfirmingAthleteSwitch(let apiKey, let athlete):
			return await replace(apiKey, athlete, over: current, switching: true, boundWork)
		}
	}

	package func change(_ change: ModelAccessChange) -> CredentialOutcome<AccessSummary> {
		let previous: AccessSummary
		do {
			let selection = try keychain(.accessSelection) { try store.accessSelection() }
			previous = AccessSummary(selection: selection ?? .credits)
		} catch {
			return .failedPreviousKept(.secureStorage(error), previous: nil)
		}
		do {
			switch change {
			case .keep:
				return .kept(previous)
			case .useCredits:
				try keychain(.accessSelection) { try store.storeAccessSelection(.credits) }
				return .replaced(AccessSummary(selection: .credits), authority: nil)
			case .signInToOpenRouter:
				return .failedPreviousKept(.signIn(.presentationUnavailable), previous: previous)
			case .selectOpenRouterModel:
				return .refused(.modelNotInCatalog)
			case .disconnectOpenRouter:
				try keychain(.openRouterAccountKey) { try store.delete(.openRouterAccountKey) }
				return .disconnected
			}
		} catch {
			return .failedPreviousKept(.secureStorage(error), previous: previous)
		}
	}

	package func storeCreditsKey(_ key: NonEmptySecret) throws(AccessUnavailable) {
		try keychain(.creditsKey) { try store.storeOpenRouterKey(key.value) }
	}

	package func storeRecovery(key: NonEmptySecret, appAccountToken: UUID)
		throws(AccessUnavailable)
	{
		try keychain(.creditsKey) { try store.storeOpenRouterKey(key.value) }
		try keychain(.appAccountToken) { try store.storeAppAccountToken(appAccountToken) }
	}

	package func creditsKey() throws(AccessUnavailable) -> NonEmptySecret? {
		try keychain(.creditsKey) { try store.openRouterKey() }.flatMap(NonEmptySecret.init)
	}

	package func creditsIdentity() throws(AccessUnavailable) -> CreditsIdentity {
		CreditsIdentity(
			appAccountToken: try appAccountToken(), hasCreditsKey: try creditsKey() != nil)
	}

	package func appAccountToken() throws(AccessUnavailable) -> UUID {
		try keychain(.appAccountToken) { try store.appAccountToken() }
	}

	#if DEBUG
		package func replaceAppAccountToken() throws(AccessUnavailable) {
			try keychain(.appAccountToken) { try store.storeAppAccountToken(UUID()) }
		}
	#endif

	private func replace(
		_ apiKey: String, _ athlete: AthleteSelection, over current: ActiveConnection?,
		switching: Bool, _ boundWork: @Sendable () async -> Bool
	) async -> CredentialOutcome<IntervalsSummary> {
		guard let secret = NonEmptySecret(apiKey) else {
			return .refused(.blankReplacementKeepsCurrent)
		}
		let id = ConnectionID()
		let credential = IntervalsCredential.apiKey(secret.value)
		let staged = IntervalsConnection(
			id: id, credential: credential, selection: athlete, resolvedAthlete: nil)
		do {
			try keychain(.intervalsConnectionStaging) { try store.stageIntervalsConnection(staged) }
		} catch {
			return .failedPreviousKept(
				.secureStorage(error), previous: await summary(ofCurrent: current))
		}
		let profile = await readProfile(staged)
		if !switching, let now = current?.connection.resolvedAthlete, let new = profile.athlete,
			now != new, await boundWork()
		{
			discardStaging()
			return .refused(.differentAthlete(current: now, new: new))
		}
		let replacement = ActiveConnection(
			id: id,
			connection: IntervalsConnection(
				id: id, credential: credential, selection: athlete, resolvedAthlete: profile.athlete
			))
		do {
			try keychain(.intervalsConnection) {
				try store.storeIntervalsConnection(replacement.connection)
			}
		} catch {
			discardStaging()
			return .failedPreviousKept(
				.secureStorage(error), previous: await summary(ofCurrent: current))
		}
		discardStaging()
		return .replaced(
			profile.summary(of: credential),
			authority: current.map { $0.account.authority(under: replacement.account) })
	}

	private func activeConnection() throws(AccessUnavailable) -> ActiveConnection? {
		guard let stored = try keychain(.intervalsConnection, { try store.intervalsConnection() })
		else { return nil }
		if let id = stored.id {
			return ActiveConnection(id: id, connection: stored)
		}
		let id = ConnectionID()
		let upgraded = IntervalsConnection(
			id: id, credential: stored.credential, selection: stored.selection,
			resolvedAthlete: stored.resolvedAthlete)
		try keychain(.intervalsConnection) { try store.storeIntervalsConnection(upgraded) }
		return ActiveConnection(id: id, connection: upgraded)
	}

	private func summary(ofCurrent current: ActiveConnection?) async -> IntervalsSummary? {
		guard let current else { return nil }
		return await read(current).summary
	}

	private func read(_ active: ActiveConnection) async -> (
		active: ActiveConnection, summary: IntervalsSummary
	) {
		let profile = await readProfile(active.connection)
		let summary = profile.summary(of: active.connection.credential)
		guard active.connection.resolvedAthlete == nil, let athlete = profile.athlete else {
			return (active, summary)
		}
		return (resolve(athlete, for: active), summary)
	}

	private func resolve(_ athlete: IntervalsAthleteID, for active: ActiveConnection)
		-> ActiveConnection
	{
		let resolved = IntervalsConnection(
			id: active.id, credential: active.connection.credential,
			selection: active.connection.selection, resolvedAthlete: athlete)
		do {
			guard let stored = try store.intervalsConnection(), stored == active.connection else {
				return active
			}
			try store.storeIntervalsConnection(resolved)
		} catch {
			diagnostics.record(
				.secureStorageFailed(.intervalsConnection, detail: String(describing: error)))
			return active
		}
		return ActiveConnection(id: active.id, connection: resolved)
	}

	private func client(for connection: IntervalsConnection) -> any IntervalsClient {
		training.makeClient(connection.credential, connection.selection, clock)
	}

	private func readProfile(_ connection: IntervalsConnection) async -> Profile {
		let client = client(for: connection)
		let athlete: AthleteProfile
		do {
			athlete = try await client.fetchAthlete()
		} catch {
			return Profile(athlete: nil, name: nil, today: nil, failure: TrainingFailure(error))
		}
		let resolved = IntervalsAthleteID(rawValue: athlete.id)
		let today = IntervalsPolicy.today(now: clock.now, timeZone: clock.timeZone)
		do {
			let days = try await client.fetchWellness(oldest: today, newest: today)
			return Profile(athlete: resolved, name: athlete.name, today: days.first, failure: nil)
		} catch {
			return Profile(
				athlete: resolved, name: athlete.name, today: nil, failure: TrainingFailure(error))
		}
	}

	private func resolve(
		_ slot: CredentialSlot, _ method: AccessMethod, _ model: ModelID,
		_ key: () throws -> String?
	) throws(AccessUnavailable) -> ResolvedAccess {
		guard let secret = try keychain(slot, key).flatMap(NonEmptySecret.init) else {
			throw .notConfigured(method)
		}
		return ResolvedAccess(
			credential: ProviderCredential(secret: secret.value, method: method), model: model)
	}

	private func recoverStaging() {
		guard !stagingRecovered else { return }
		stagingRecovered = true
		discardStaging()
	}

	private func discardStaging() {
		do {
			try store.delete(.intervalsConnectionStaging)
		} catch {
			diagnostics.record(
				.secureStorageFailed(.intervalsConnectionStaging, detail: String(describing: error))
			)
		}
	}

	private func keychain<Value>(_ slot: CredentialSlot, _ body: () throws -> Value)
		throws(AccessUnavailable) -> Value
	{
		do {
			return try body()
		} catch let keychain as KeychainStoreError
			where keychain.status == errSecInteractionNotAllowed
		{
			throw .secureStorageLocked
		} catch let keychain as KeychainStoreError where keychain.status == errSecDecode {
			throw .malformedStoredCredential(slot)
		} catch {
			diagnostics.record(.secureStorageFailed(slot, detail: String(describing: error)))
			throw .secureStorageUnavailable
		}
	}
}

private struct ActiveConnection {
	let id: ConnectionID
	let connection: IntervalsConnection

	var account: TrainingAccount {
		.intervals(connection: id, athlete: connection.resolvedAthlete)
	}
}

private struct Profile {
	let athlete: IntervalsAthleteID?
	let name: String?
	let today: WellnessDay?
	let failure: TrainingFailure?

	func summary(of credential: IntervalsCredential) -> IntervalsSummary {
		IntervalsSummary(
			keySuffix: credential.keySuffix, athleteName: name, today: today,
			displayUnavailable: failure)
	}
}
