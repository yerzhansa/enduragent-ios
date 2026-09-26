import Foundation
import Security
import Testing

@testable import EnduragentCoach

@Suite struct CredentialVaultTests {
	let transport = FakeModelTransport()
	let records = InMemoryRecordLog()
	let clock = FixedClock(now: "1998-06-13T08:00:00+02:00", timeZone: "Europe/Amsterdam")
	let ada = FakeIntervalsClient(athleteName: "Ada Kovač", ftp: 250, athleteId: "i1001")
	let bo = FakeIntervalsClient(athleteName: "Bo Lind", ftp: 240, athleteId: "i2002")
	let offline = FakeIntervalsClient(athleteName: "Nobody", ftp: 200, athleteId: "i3003")
	let built = CredentialLog()

	init() {
		offline.loadFailure = IntervalsError(
			code: "down", details: "intervals.icu is unavailable.", status: 503)
	}

	var training: TrainingService {
		let (ada, bo, offline, built) = (ada, bo, offline, built)
		return .fake { credential in
			built.append(credential)
			switch credential {
			case .apiKey("other-athlete"): return bo
			case .apiKey("icu-offline"): return offline
			default: return ada
			}
		}
	}

	var adaSummary: IntervalsSummary {
		IntervalsSummary(
			keySuffix: "-key", athleteName: "Ada Kovač", today: nil, displayUnavailable: nil)
	}

	func coach(_ secrets: any SecretStore) -> Coach {
		Coach(
			sport: .cycling,
			ports: CoachPorts(
				records: records, secrets: secrets, models: .scripted(transport),
				training: training, credits: .fake(FakeCreditsClient()), clock: clock),
			builtInModel: testModel,
			language: .init(ui: .en, coachReply: nil),
			coalescing: quickWindow
		)
	}

	func vault(_ store: any SecretStore) -> CredentialVault {
		testVault(store, training: training, clock: clock)
	}

	func account(_ connection: IntervalsConnection) throws -> TrainingAccount {
		.intervals(connection: try #require(connection.id), athlete: connection.resolvedAthlete)
	}

	func claimAccount(after text: String, on coach: Coach) async throws -> TrainingAccount {
		transport.script = [.text("Noted."), .finish(reason: .stop)]
		_ = try await coach.sendAndSettle(text)
		let claims = try await records.fetch(
			RecordQuery(scope: .deviceLocal([.turnClaim]), chatId: "main"))
		return try #require(claims.records.last?.account)
	}

	func proposeRide(on coach: Coach) async throws -> PendingProposal {
		transport.script = [
			.toolCall(
				name: "intervals_create_workout",
				arguments:
					#"{"date":"1998-06-14","workout":{"name":"Endurance","steps":[{"type":"steady","duration":{"value":60,"unit":"minutes"},"power":{"kind":"percent_ftp","low":56,"high":75}}]}}"#
			),
			.finish(reason: .toolCalls),
			.text("I've prepared the ride. Confirm to add it."),
			.finish(reason: .stop),
		]
		_ = try await coach.sendAndSettle("Give me an endurance ride for tomorrow")
		return try #require(await coach.currentSnapshot(.main)?.pendingProposal)
	}

	@Test func blankReplacementKeepsTheWorkingKey() async throws {
		let secrets = keyedSecrets()
		let coach = coach(secrets)
		#expect(
			await coach.changeTraining(.replace(apiKey: " \n ", athlete: .keyOwner))
				== .refused(.blankReplacementKeepsCurrent))
		#expect(try secrets.intervalsConnection() == testConnection)
		#expect(try secrets.stagedIntervalsConnection() == nil)
		#expect(
			try await claimAccount(after: "Is Thursday on?", on: coach) == account(testConnection))
		#expect(built.credentials == [.apiKey("icu-test-key")])
	}

	@Test func cancelKeepsTheWorkingKey() async throws {
		let secrets = keyedSecrets()
		let coach = coach(secrets)
		#expect(await coach.changeTraining(.keep) == .kept(adaSummary))
		#expect(try secrets.intervalsConnection() == testConnection)
		#expect(
			try await claimAccount(after: "Is Thursday on?", on: coach) == account(testConnection))
	}

	@Test func failedWriteKeepsPreviousItemAndNextAttemptUsesIt() async throws {
		let secrets = keyedSecrets()
		let coach = coach(secrets)
		secrets.failNextWrite = true
		#expect(
			await coach.changeTraining(.replace(apiKey: "icu-new-key", athlete: .keyOwner))
				== .failedPreviousKept(
					.secureStorage(.secureStorageUnavailable), previous: adaSummary))
		#expect(try secrets.intervalsConnection() == testConnection)
		#expect(
			try await claimAccount(after: "Is Thursday on?", on: coach) == account(testConnection))
		#expect(!built.credentials.contains(.apiKey("icu-new-key")))

		let memory = MemorySecretStoreBacking()
		let keychain = ICloudKeychainStore(backing: memory)
		try keychain.storeIntervalsConnection(testConnection)
		memory.failWrites(CredentialSlot.intervalsConnection.rawValue, with: errSecNotAvailable)
		let flipFailed = await vault(keychain).change(
			.replace(apiKey: "icu-new-key", athlete: .keyOwner), boundWork: { false })
		#expect(
			flipFailed
				== .failedPreviousKept(
					.secureStorage(.secureStorageUnavailable), previous: adaSummary))
		#expect(try keychain.intervalsConnection() == testConnection)
		#expect(try keychain.stagedIntervalsConnection() == nil)
	}

	@Test func profileReadFailureFlipsWithUnverifiableAuthority() async throws {
		let secrets = keyedSecrets()
		let coach = coach(secrets)
		let outcome = await coach.changeTraining(
			.replace(apiKey: "icu-offline", athlete: .keyOwner))
		#expect(
			outcome
				== .replaced(
					IntervalsSummary(
						keySuffix: "line", athleteName: nil, today: nil,
						displayUnavailable: .temporarilyUnavailable),
					authority: .unverifiable))
		let active = try #require(try secrets.intervalsConnection())
		#expect(active.credential == .apiKey("icu-offline"))
		#expect(active.resolvedAthlete == nil)
		#expect(active.id != testConnection.id)
		#expect(await coach.status().notice?.key == Catalog.coachErrorIntervalsTransient)
		#expect(try await claimAccount(after: "Is Thursday on?", on: coach) == account(active))
	}

	@Test func malformedKeyFailsTheTurnAndTheFailureSurvivesRelaunch() async throws {
		let memory = MemorySecretStoreBacking(items: [
			CredentialSlot.creditsKey.rawValue: Data([0xFF, 0xFE, 0xFD])
		])
		let keychain = ICloudKeychainStore(backing: memory)
		let settled = try await coach(keychain).sendAndSettle("Is Thursday on?")
		guard case .failed(let failed) = settled else {
			Issue.record("expected a failed turn, got \(settled)")
			return
		}
		#expect(failed.notice.key == Catalog.accessErrorNotConfigured)
		let reopened = try #require(await coach(keychain).currentSnapshot(.main))
		#expect(reopened.turns.map(\.state) == [settled])
		#expect(transport.requests.isEmpty)
	}

	@Test func differentAthleteWithBoundWorkIsRefusedAndStagingDeleted() async throws {
		let secrets = keyedSecrets()
		let coach = coach(secrets)
		_ = try await proposeRide(on: coach)
		let current = try #require(IntervalsAthleteID(rawValue: "i1001"))
		let new = try #require(IntervalsAthleteID(rawValue: "i2002"))
		#expect(
			await coach.changeTraining(.replace(apiKey: "other-athlete", athlete: .keyOwner))
				== .refused(.differentAthlete(current: current, new: new)))
		#expect(try secrets.stagedIntervalsConnection() == nil)
		#expect(try secrets.intervalsConnection() == testConnection)
		#expect(await coach.currentSnapshot(.main)?.pendingProposal != nil)
		#expect(
			try await claimAccount(after: "Is Thursday on?", on: coach) == account(testConnection))
	}

	@Test func differentAthleteWithoutBoundWorkFlips() async throws {
		let secrets = keyedSecrets()
		let outcome = await coach(secrets).changeTraining(
			.replace(apiKey: "other-athlete", athlete: .keyOwner))
		guard case .replaced(let summary, .changed?) = outcome else {
			Issue.record("expected a replacement with changed authority, got \(outcome)")
			return
		}
		#expect(summary.athleteName == "Bo Lind")
		#expect(try secrets.intervalsConnection()?.resolvedAthlete?.rawValue == "i2002")
	}

	@Test func confirmingAthleteSwitchFlips() async throws {
		let secrets = keyedSecrets()
		let coach = coach(secrets)
		let pending = try await proposeRide(on: coach)
		#expect(pending.account == (try account(testConnection)))
		#expect(pending.confirmable(under: await coach.status()))
		let outcome = await coach.changeTraining(
			.replaceConfirmingAthleteSwitch(apiKey: "other-athlete", athlete: .keyOwner))
		#expect(
			outcome
				== .replaced(
					IntervalsSummary(
						keySuffix: "lete", athleteName: "Bo Lind", today: nil,
						displayUnavailable: nil),
					authority: .changed))
		let active = try #require(try secrets.intervalsConnection())
		#expect(active.resolvedAthlete?.rawValue == "i2002")
		let status = await coach.status()
		guard case .connected(let summary, let switched) = status.training else {
			Issue.record("expected a connected account, got \(status.training)")
			return
		}
		#expect(summary.athleteName == "Bo Lind")
		#expect(switched == (try account(active)))
		#expect(!pending.confirmable(under: status))
		#expect(await coach.currentSnapshot(.main)?.pendingProposal?.nonce == pending.nonce)
		let reopened = try #require(
			await self.coach(secrets).currentSnapshot(.main)?.pendingProposal)
		#expect(reopened.nonce == pending.nonce)
		#expect(reopened.account == (try account(testConnection)))
		#expect(!reopened.confirmable(under: status))
	}

	@Test func lockedStoreReportsSecureStorageLocked() async throws {
		let secrets = keyedSecrets()
		secrets.locked = true
		await #expect(throws: AccessUnavailable.secureStorageLocked) {
			try await vault(secrets).modelAccess(builtInModel: testModel)
		}
		let status = await coach(secrets).status()
		#expect(status.setup == .accessTemporarilyUnavailable(.secureStorageLocked))
		#expect(status.training == .unavailable(.secureStorageLocked))
		#expect(status.notice?.key == Catalog.accessErrorLocked)
		#expect(status.notice?.action == nil)

		let memory = MemorySecretStoreBacking()
		memory.fail(CredentialSlot.accessSelection.rawValue, with: errSecInteractionNotAllowed)
		await #expect(throws: AccessUnavailable.secureStorageLocked) {
			try await vault(ICloudKeychainStore(backing: memory)).modelAccess(
				builtInModel: testModel)
		}
	}

	@Test func malformedItemReportsSlotWithoutContent() async throws {
		let memory = MemorySecretStoreBacking(items: [
			CredentialSlot.creditsKey.rawValue: Data([0xFF, 0xFE, 0xFD]),
			CredentialSlot.intervalsConnection.rawValue: Data(
				#"{"credential":"sk-or-v0-leaked-content"}"#.utf8),
		])
		let diagnostics = DiagnosticsLog(clock: clock)
		let vault = CredentialVault(
			store: ICloudKeychainStore(backing: memory), training: training, clock: clock,
			diagnostics: diagnostics)
		await #expect(throws: AccessUnavailable.malformedStoredCredential(.creditsKey)) {
			try await vault.modelAccess(builtInModel: testModel)
		}
		do {
			_ = try await vault.trainingConnection()
			Issue.record("expected a malformed intervals item")
		} catch {
			#expect(error == .malformedStoredCredential(.intervalsConnection))
			#expect(!String(describing: error).contains("leaked"))
		}
		#expect(diagnostics.entries.isEmpty)
	}

	@Test func resolverReadsOnlyTheSelectedMethodKey() async throws {
		let secrets = FakeSecretStore()
		try secrets.storeOpenRouterKey("sk-or-credits")
		try secrets.storeOpenRouterAccountKey("sk-or-account")
		let model = ModelID(rawValue: "test/account-model")
		try secrets.storeAccessSelection(
			.openRouterAccount(
				model: model,
				consent: ProviderConsent(provider: "Test Provider", model: model, at: clock.now)))
		let vault = vault(secrets)
		#expect(
			try await vault.modelAccess(builtInModel: testModel)
				== ResolvedAccess(
					credential: ProviderCredential(
						secret: "sk-or-account", method: .openRouterAccount),
					model: model))
		#expect(secrets.reads == [.accessSelection, .openRouterAccountKey])
		try secrets.delete(.openRouterAccountKey)
		await #expect(throws: AccessUnavailable.notConfigured(.openRouterAccount)) {
			try await vault.modelAccess(builtInModel: testModel)
		}
		#expect(!secrets.reads.contains(.creditsKey))
		try secrets.storeAccessSelection(.credits)
		#expect(
			try await vault.modelAccess(builtInModel: testModel)
				== testAccess(secret: "sk-or-credits"))
		#expect(secrets.reads.suffix(2) == [.accessSelection, .creditsKey])
		#expect(secrets.reads.filter { $0 == .openRouterAccountKey }.count == 2)
	}

	@Test func recoverStagingDeletesLeftoverAtLaunch() async throws {
		let secrets = keyedSecrets()
		try secrets.stageIntervalsConnection(
			IntervalsConnection(
				id: ConnectionID(), credential: .apiKey("icu-half-written"), selection: .keyOwner,
				resolvedAthlete: nil))
		let launched = try await vault(secrets).trainingConnection()
		#expect(try secrets.stagedIntervalsConnection() == nil)
		#expect(launched.account == (try account(testConnection)))
	}

	@Test func disconnectLeavesTheNextTurnUnconnected() async throws {
		let secrets = keyedSecrets()
		let coach = coach(secrets)
		#expect(await coach.changeTraining(.disconnect) == .disconnected)
		#expect(try secrets.intervalsConnection() == nil)
		#expect(await coach.status().training == .unconnected)
		#expect(try await claimAccount(after: "Is Thursday on?", on: coach) == .unconnected)
	}

	@Test func keyStoredAfterLaunchReachesTheNextAttempt() async throws {
		let secrets = FakeSecretStore()
		try secrets.storeOpenRouterKey(testKey)
		let coach = coach(secrets)
		#expect(try await claimAccount(after: "Is Thursday on?", on: coach) == .unconnected)
		guard
			case .replaced = await coach.changeTraining(
				.replace(apiKey: "icu-later-key", athlete: .keyOwner))
		else {
			Issue.record("expected the key to be stored")
			return
		}
		let connected = try #require(try secrets.intervalsConnection())
		#expect(try await claimAccount(after: "How was my week?", on: coach) == account(connected))
		#expect(built.credentials.last == .apiKey("icu-later-key"))
	}

	@Test func useCreditsSelectsCreditsAndSignInKeepsThePreviousMethod() async throws {
		let secrets = keyedSecrets()
		let coach = coach(secrets)
		#expect(
			await coach.changeModelAccess(.signInToOpenRouter(model: testModel, consent: consent))
				== .failedPreviousKept(
					.signIn(.presentationUnavailable), previous: AccessSummary(selection: .credits))
		)
		#expect(try secrets.accessSelection() == nil)
		#expect(
			await coach.changeModelAccess(.useCredits)
				== .replaced(AccessSummary(selection: .credits), authority: nil))
		#expect(try secrets.accessSelection() == .credits)
		#expect(await coach.status().setup == .ready)
	}

	@Test func perAttemptResolutionStaysUnderFiftyMilliseconds() async throws {
		let keychain = ICloudKeychainStore(backing: MemorySecretStoreBacking())
		try keychain.storeOpenRouterKey(testKey)
		try keychain.storeIntervalsConnection(testConnection)
		let vault = vault(keychain)
		var samples: [Duration] = []
		for _ in 0..<200 {
			let started = ContinuousClock.now
			_ = try await vault.modelAccess(builtInModel: testModel)
			_ = try await vault.trainingConnection()
			samples.append(ContinuousClock.now - started)
		}
		let sorted = samples.sorted()
		#expect(sorted[sorted.count / 2] < .milliseconds(50))
		#expect(sorted[sorted.count * 95 / 100] < .milliseconds(50))
	}

	var consent: ProviderConsent {
		ProviderConsent(provider: "Test Provider", model: testModel, at: clock.now)
	}

	func testAccess(secret: String) -> ResolvedAccess {
		ResolvedAccess(
			credential: ProviderCredential(secret: secret, method: .credits), model: testModel)
	}
}

final class CredentialLog: @unchecked Sendable {
	private let lock = NSLock()
	private var built: [IntervalsCredential] = []

	var credentials: [IntervalsCredential] {
		lock.withLock { built }
	}

	func append(_ credential: IntervalsCredential) {
		lock.withLock { built.append(credential) }
	}
}
