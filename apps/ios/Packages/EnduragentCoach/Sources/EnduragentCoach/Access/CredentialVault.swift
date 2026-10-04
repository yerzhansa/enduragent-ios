import Foundation
import Security

package actor CredentialVault {
	let store: any SecretStore
	let catalog: ModelCatalog
	let ledger: Ledger
	let clock: any Clock
	let rejectionChanges = Turnstile()
	var rejectedKeys: Set<OpenRouterCredentialRef> = []
	var rejectionReadFailure: AccessUnavailable?
	package nonisolated let accessUpdates: AsyncStream<Void>
	let accessUpdate: AsyncStream<Void>.Continuation
	let signInService: OpenRouterSignInService?
	var signInFlight: SignInFlight?
	var consentContext: ConsentContext?
	var pendingModelChoice: ConsentContext?
	private let display: TrainingDisplayReader
	private let diagnostics: DiagnosticsLog
	private let changes = Turnstile()
	private var trainingIdentity: TrainingIdentityRead?

	package init(
		store: any SecretStore, training: TrainingService, clock: any Clock, ledger: Ledger,
		diagnostics: DiagnosticsLog, catalog: ModelCatalog = .bundled,
		signInService: OpenRouterSignInService? = nil
	) {
		(accessUpdates, accessUpdate) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
		self.store = store
		self.ledger = ledger
		self.clock = clock
		self.catalog = catalog
		self.signInService = signInService
		self.display = TrainingDisplayReader(training: training, clock: clock)
		self.diagnostics = diagnostics
	}

	package func trainingConnection(recheck: Bool = false) async throws(AccessUnavailable)
		-> TrainingConnection
	{
		if recheck { invalidateTrainingIdentity() }
		guard let (active, profile) = try await checkedConnection() else { return .unconnected }
		guard case .available = profile else {
			if case .failed(let failure) = profile { throw .trainingIdentityUnverified(failure) }
			throw .trainingIdentityUnverified(.temporarilyUnavailable)
		}
		return TrainingConnection(
			account: active.account(verifiedBy: profile), client: display.client(for: active))
	}

	package func invalidateTrainingIdentity() {
		trainingIdentity = nil
	}

	package func storedTrainingStatus() -> TrainingStatus {
		do {
			guard let active = try activeConnection() else { return .unconnected }
			let profile =
				trainingIdentity.flatMap {
					$0.connection.matches(active) ? $0.profile : nil
				} ?? .waiting
			return .connected(
				IntervalsSummary(
					connectionID: active.id, keySuffix: active.credential.keySuffix,
					profile: profile),
				account: active.account(verifiedBy: profile))
		} catch {
			return .unavailable(error)
		}
	}

	package func refreshTrainingDisplay(
		from summary: IntervalsSummary,
		isCurrent: @Sendable () async -> Bool,
		publish: @Sendable (TrainingStatus) async -> Void
	) async {
		let active: IntervalsConnection
		let profile: IntervalsProfileState
		do {
			guard let checked = try await checkedConnection(),
				checked.0.id == summary.connectionID, await isCurrent()
			else { return }
			(active, profile) = checked
		} catch {
			await publish(.unavailable(error))
			return
		}
		guard let readID = trainingIdentity?.id else { return }
		let refreshed = display.summary(for: active, profile: profile)
		guard let status = resolvedDisplay(refreshed, for: active, readID: readID) else { return }
		await publish(status)
		guard case .available(let athlete) = profile, await isCurrent() else { return }
		let wellness = await display.wellness(for: active)
		guard await isCurrent() else { return }
		let complete = display.summary(
			for: active,
			profile: .available(
				IntervalsProfile(
					athleteID: athlete.athleteID, name: athlete.name, wellness: wellness)))
		guard let status = resolvedDisplay(complete, for: active, readID: readID) else { return }
		await publish(status)
	}

	private func checkedConnection() async throws(AccessUnavailable)
		-> (IntervalsConnection, IntervalsProfileState)?
	{
		while let active = try activeConnection() {
			let read: TrainingIdentityRead
			if let current = trainingIdentity, current.connection.matches(active) {
				read = current
			} else {
				let display = self.display
				read = TrainingIdentityRead(
					connection: active, state: .reading(Task { await display.profile(for: active) })
				)
				trainingIdentity = read
			}
			let profile: IntervalsProfileState
			switch read.state {
			case .reading(let task): profile = await task.value
			case .checked(let result): profile = result
			}
			guard let stored = try activeConnection() else { return nil }
			guard read.connection.matches(stored), trainingIdentity?.id == read.id else { continue }
			trainingIdentity = TrainingIdentityRead(
				connection: stored, state: .checked(profile), id: read.id)
			let summary = display.summary(for: stored, profile: profile)
			guard let status = resolvedDisplay(summary, for: stored, readID: read.id) else {
				continue
			}
			if case .unavailable(let error) = status { throw error }
			guard let resolved = try activeConnection(), read.connection.matches(resolved) else {
				continue
			}
			return (resolved, profile)
		}
		trainingIdentity = nil
		return nil
	}

	package func change(
		_ change: IntervalsConnectionChange, boundWork: @Sendable () async -> Bool
	) async -> CredentialOutcome<IntervalsSummary> {
		await changes.pass { await applying(change, boundWork: boundWork) }
	}

	private func applying(
		_ change: IntervalsConnectionChange, boundWork: @Sendable () async -> Bool
	) async -> CredentialOutcome<IntervalsSummary> {
		let current: IntervalsConnection?
		do {
			current = try activeConnection()
		} catch .malformedStoredCredential(.intervalsConnection) {
			switch change {
			case .replace, .replaceConfirmingAthleteSwitch:
				current = nil
			case .keep:
				return .kept(nil)
			case .disconnect:
				return .failedPreviousKept(
					.secureStorage(.malformedStoredCredential(.intervalsConnection)), previous: nil)
			}
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

	package func storeCreditsKey(_ key: NonEmptySecret, mintedFor token: UUID) throws {
		let stored = try keychain(.creditsAccount) {
			guard var account = try store.creditsAccount(), account.appAccountToken == token else {
				return false
			}
			account.key = key.value
			try store.storeCreditsAccount(account)
			return true
		}
		guard stored else { throw CreditsFailure.accountChanged }
	}

	package func storeRecovery(key: NonEmptySecret, appAccountToken: UUID)
		throws(AccessUnavailable)
	{
		try keychain(.creditsAccount) {
			try store.storeCreditsAccount(
				CreditsAccount(appAccountToken: appAccountToken, key: key.value))
		}
	}

	package func creditsKey() throws(AccessUnavailable) -> NonEmptySecret? {
		try keychain(.creditsAccount) { try store.creditsAccount()?.key }.flatMap(
			NonEmptySecret.init)
	}

	package func creditsIdentity() throws(AccessUnavailable) -> CreditsIdentity {
		let account = try keychain(.creditsAccount) { try store.creditsAccount() }
		return CreditsIdentity(
			appAccountToken: account?.appAccountToken,
			hasCreditsKey: account?.key.flatMap(NonEmptySecret.init) != nil)
	}

	package func prepareCreditsAccount() throws(AccessUnavailable) -> UUID {
		try keychain(.creditsAccount) { try store.prepareCreditsAccount().appAccountToken }
	}

	#if DEBUG
		package func replaceAppAccountToken() throws(AccessUnavailable) {
			try keychain(.creditsAccount) {
				let account = CreditsAccount(
					appAccountToken: UUID(), key: try store.creditsAccount()?.key)
				try store.storeCreditsAccount(account)
			}
		}
	#endif

	private func replace(
		_ apiKey: String, _ athlete: AthleteSelection, over current: IntervalsConnection?,
		switching: Bool, _ boundWork: @Sendable () async -> Bool
	) async -> CredentialOutcome<IntervalsSummary> {
		guard let secret = NonEmptySecret(apiKey) else {
			return .refused(current == nil ? .blankConnection : .blankReplacementKeepsCurrent)
		}
		let id = ConnectionID()
		let credential = IntervalsCredential.apiKey(secret.value)
		let candidate = IntervalsConnection(
			id: id, credential: credential, selection: athlete, resolvedAthlete: nil)
		let profile = await display.profile(for: candidate)
		let resolved: IntervalsAthleteID?
		if case .available(let athlete) = profile {
			resolved = athlete.athleteID
		} else {
			resolved = nil
		}
		if !switching, let now = current?.resolvedAthlete, let new = resolved,
			now != new, await boundWork()
		{
			return .refused(.differentAthlete(current: now, new: new))
		}
		let replacement = IntervalsConnection(
			id: id, credential: credential, selection: athlete, resolvedAthlete: resolved)
		do {
			let saved: IntervalsConnection?
			do {
				saved = try activeConnection()
			} catch .malformedStoredCredential(.intervalsConnection) where current == nil {
				saved = nil
			}
			switch (current, saved) {
			case (nil, nil): break
			case (let previous?, let latest?) where previous.matches(latest): break
			default: return .kept(await summary(ofCurrent: saved))
			}
			try keychain(.intervalsConnection) {
				try store.storeIntervalsConnection(replacement)
			}
		} catch {
			return .failedPreviousKept(
				.secureStorage(error), previous: await summary(ofCurrent: current))
		}
		trainingIdentity = TrainingIdentityRead(connection: replacement, state: .checked(profile))
		return .replaced(
			display.summary(for: replacement, profile: profile),
			authority: current.map { $0.account.authority(under: replacement.account) })
	}

	private func activeConnection() throws(AccessUnavailable) -> IntervalsConnection? {
		try keychain(.intervalsConnection) { try store.intervalsConnection() }
	}

	private func summary(ofCurrent current: IntervalsConnection?) async -> IntervalsSummary? {
		guard let current else { return nil }
		return await display.summary(for: current)
	}

	private func resolvedDisplay(
		_ summary: IntervalsSummary, for active: IntervalsConnection, readID: UUID
	) -> TrainingStatus? {
		do {
			guard let stored = try activeConnection(), active.matches(stored),
				trainingIdentity?.id == readID
			else { return nil }
			if let current = trainingIdentity, current.connection.matches(stored) {
				trainingIdentity = TrainingIdentityRead(
					connection: stored, state: .checked(summary.profile), id: current.id)
			}
			guard case .available(let profile) = summary.profile,
				stored.resolvedAthlete != profile.athleteID
			else {
				return .connected(summary, account: stored.account(verifiedBy: summary.profile))
			}
			let resolved = IntervalsConnection(
				id: stored.id, credential: stored.credential,
				selection: stored.selection, resolvedAthlete: profile.athleteID)
			do {
				try keychain(.intervalsConnection) { try store.storeIntervalsConnection(resolved) }
				return .connected(summary, account: resolved.account(verifiedBy: summary.profile))
			} catch {
				return .connected(summary, account: stored.account(verifiedBy: summary.profile))
			}
		} catch { return .unavailable(error) }
	}

	func keychain<Value>(_ slot: CredentialSlot, _ body: () throws -> Value)
		throws(AccessUnavailable) -> Value
	{
		do {
			return try body()
		} catch {
			let failure = KeychainStoreError(error)
			record(failure, for: slot)
			throw classify(failure, for: slot)
		}
	}

	private func record(_ failure: KeychainStoreError, for slot: CredentialSlot) {
		guard classify(failure, for: slot) != .secureStorageLocked else { return }
		diagnostics.record(.secureStorageFailed(slot, failure: failure))
	}

	private func classify(_ failure: KeychainStoreError, for slot: CredentialSlot)
		-> AccessUnavailable
	{
		switch failure.status {
		case errSecInteractionNotAllowed: .secureStorageLocked
		case errSecDecode: .malformedStoredCredential(slot)
		default: .secureStorageUnavailable
		}
	}
}
