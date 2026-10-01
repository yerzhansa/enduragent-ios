import EnduragentCoachFixtures
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

	@Test(arguments: [errSecNotAvailable, errSecDecode])
	func secureStorageDiagnosticsKeepStatus(_ status: OSStatus) async throws {
		let backing = FixtureSecretStoreBacking()
		let secrets = keyedSecrets(backing: backing)
		let coach = await coach(secrets)
		backing.failWrites(CredentialSlot.intervalsConnection.rawValue, with: status)
		let outcome = await coach.changeTraining(
			.replace(apiKey: "icu-new-key", athlete: .keyOwner))
		let unavailable: AccessUnavailable =
			status == errSecDecode
			? .malformedStoredCredential(.intervalsConnection) : .secureStorageUnavailable
		#expect(outcome == .failedPreviousKept(.secureStorage(unavailable), previous: adaSummary))
		let entry = try #require(coach.diagnostics.entries.last)
		guard case .secureStorageFailed(let slot, let failure) = entry.event else {
			Issue.record("expected a secure storage diagnostic")
			return
		}
		#expect(slot == .intervalsConnection)
		#expect(failure == KeychainStoreError.keychain(status))
	}

	init() {
		offline.loadFailure = IntervalsError(
			code: "down", details: "intervals.icu is unavailable.", status: 503)
	}

	var training: TrainingService {
		let (ada, bo, offline, built) = (ada, bo, offline, built)
		return .fake { credential, athlete in
			built.append(credential, athlete)
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

	func coach(_ secrets: any SecretStore, log: (any RecordLog)? = nil) async -> Coach {
		await consentingCoach(
			Coach(
				sport: .cycling,
				ports: CoachPorts(
					records: RecordStore(log: log ?? records), secrets: secrets,
					models: .scripted(transport),
					training: training, credits: .fake(FakeCreditsClient()),
					host: ImmediateExecutionHost(), clock: clock),
				builtInModel: testModel,
				deviceLanguage: .en,
				coalescing: quickWindow
			))
	}

	func vault(_ store: any SecretStore) -> CredentialVault {
		testVault(store, training: training, clock: clock)
	}

	func account(_ connection: IntervalsConnection) -> TrainingAccount {
		.intervals(connection: connection.id, athlete: connection.resolvedAthlete)
	}

	func claimAccount(after text: String, on coach: Coach) async throws -> TrainingAccount {
		transport.respond = ScriptedReply.sequence(
			[.text("Noted."), .finish(reason: .stop)], otherwise: transport.respond)
		_ = try await coach.sendAndSettle(text)
		let claims = try await records.fetch(
			RecordQuery(scope: .deviceLocal([.turnClaim]), chatId: "main"))
		return try #require(claims.records.last?.account)
	}

	func proposeRide(on coach: Coach) async throws -> ReviewSnapshot {
		transport.respond = ScriptedReply.sequence(
			[
				.toolCall(
					name: "intervals_create_workout",
					arguments:
						#"{"date":"1998-06-14","workout":{"name":"Endurance","steps":[{"type":"steady","duration":{"value":60,"unit":"minutes"},"power":{"kind":"percent_ftp","low":56,"high":75}}]}}"#
				),
				.finish(reason: .toolCalls),
				.text("I've prepared the ride. Confirm to add it."),
				.finish(reason: .stop),
			], otherwise: transport.respond)
		_ = try await coach.sendAndSettle("Give me an endurance ride for tomorrow")
		return try #require(await coach.currentSnapshot(.main)?.review)
	}

	@Test func blankReplacementKeepsTheWorkingKey() async throws {
		let secrets = keyedSecrets()
		let coach = await coach(secrets)
		#expect(
			await coach.changeTraining(.replace(apiKey: " \n ", athlete: .keyOwner))
				== .refused(.blankReplacementKeepsCurrent))
		#expect(try secrets.intervalsConnection() == testConnection)
		#expect(
			try await claimAccount(after: "Is Thursday on?", on: coach) == account(testConnection))
		#expect(built.credentials == [.apiKey("icu-test-key")])
	}

	@Test func cancelKeepsTheWorkingKey() async throws {
		let secrets = keyedSecrets()
		let coach = await coach(secrets)
		#expect(await coach.changeTraining(.keep) == .kept(adaSummary))
		#expect(try secrets.intervalsConnection() == testConnection)
		#expect(
			try await claimAccount(after: "Is Thursday on?", on: coach) == account(testConnection))
	}

	@Test func failedWriteKeepsPreviousItemAndNextAttemptUsesIt() async throws {
		let backing = FixtureSecretStoreBacking()
		let secrets = keyedSecrets(backing: backing)
		let coach = await coach(secrets)
		backing.failNextWrite = true
		#expect(
			await coach.changeTraining(.replace(apiKey: "icu-new-key", athlete: .keyOwner))
				== .failedPreviousKept(
					.secureStorage(.secureStorageUnavailable), previous: adaSummary))
		#expect(try secrets.intervalsConnection() == testConnection)
		#expect(
			try await claimAccount(after: "Is Thursday on?", on: coach) == account(testConnection))
		#expect(built.credentials.contains(.apiKey("icu-new-key")))

		let memory = FixtureSecretStoreBacking()
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
	}

	@Test func profileReadFailureFlipsWithUnverifiableAuthority() async throws {
		let secrets = keyedSecrets()
		let coach = await coach(secrets)
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

	@Test func differentAthleteWithBoundWorkIsRefused() async throws {
		let secrets = keyedSecrets()
		let coach = await coach(secrets)
		_ = try await proposeRide(on: coach)
		let current = try #require(IntervalsAthleteID(rawValue: "i1001"))
		let new = try #require(IntervalsAthleteID(rawValue: "i2002"))
		#expect(
			await coach.changeTraining(.replace(apiKey: "other-athlete", athlete: .keyOwner))
				== .refused(.differentAthlete(current: current, new: new)))
		#expect(try secrets.intervalsConnection() == testConnection)
		#expect(await coach.currentSnapshot(.main)?.review?.notice == nil)
		#expect(
			try await claimAccount(after: "Is Thursday on?", on: coach) == account(testConnection))
	}

	@Test func unverifiedAthleteResolvesOnTheNextReadAndThenRefusesAnotherAthlete() async throws {
		let secrets = keyedSecrets()
		let coach = await coach(secrets)
		guard
			case .replaced(_, .unverifiable?) = await coach.changeTraining(
				.replace(apiKey: "icu-offline", athlete: .keyOwner))
		else {
			Issue.record("expected an unverifiable replacement")
			return
		}
		#expect(try secrets.intervalsConnection()?.resolvedAthlete == nil)
		offline.loadFailure = nil
		let status = await coach.status()
		let resolved = try #require(try secrets.intervalsConnection())
		let athlete = try #require(IntervalsAthleteID(rawValue: "i3003"))
		#expect(resolved.resolvedAthlete == athlete)
		#expect(status.trainingAccount == account(resolved))
		_ = try await proposeRide(on: coach)
		let other = try #require(IntervalsAthleteID(rawValue: "i2002"))
		#expect(
			await coach.changeTraining(.replace(apiKey: "other-athlete", athlete: .keyOwner))
				== .refused(.differentAthlete(current: athlete, new: other)))
		#expect(try secrets.intervalsConnection() == resolved)
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
		let coach = await coach(secrets)
		let pending = try await proposeRide(on: coach)
		#expect(pending.notice == nil)
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
		#expect(switched == account(active))
		let switchedReview = try #require(await coach.currentSnapshot(.main)?.review)
		#expect(switchedReview.ref.set == pending.ref.set)
		#expect(switchedReview.notice?.kind == .accountChanged)
		#expect(switchedReview.controls == .none)
		let reopened = try #require(await self.coach(secrets).currentSnapshot(.main)?.review)
		#expect(reopened.ref.set == pending.ref.set)
		#expect(reopened.notice?.kind == .accountChanged)
		let proposals = try await records.fetch(
			RecordQuery(scope: .deviceLocal([.pendingProposal]), chatId: "main")
		).records
		#expect(proposals.map(\.account) == [account(testConnection)])
	}

	@Test func disconnectLeavesTheNextTurnUnconnected() async throws {
		let secrets = keyedSecrets()
		let coach = await coach(secrets)
		#expect(await coach.changeTraining(.disconnect) == .disconnected)
		#expect(try secrets.intervalsConnection() == nil)
		#expect(await coach.status().training == .unconnected)
		#expect(try await claimAccount(after: "Is Thursday on?", on: coach) == .unconnected)
	}

	@Test func keyStoredAfterLaunchReachesTheNextAttempt() async throws {
		let secrets = ICloudKeychainStore(backing: FixtureSecretStoreBacking())
		try secrets.storeCreditsAccount(
			CreditsAccount(appAccountToken: UUID(), key: testKey))
		let coach = await coach(secrets)
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
		let coach = await coach(secrets)
		#expect(
			await coach.changeModelAccess(.signInToOpenRouter(model: testModel))
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

	func testAccess(secret: String) -> ResolvedAccess {
		ResolvedAccess(
			credential: ProviderCredential(secret: secret, method: .credits), model: testModel)
	}
}

final class CredentialLog: @unchecked Sendable {
	private let lock = NSLock()
	private var built: [(IntervalsCredential, AthleteSelection)] = []

	var credentials: [IntervalsCredential] {
		lock.withLock { built.map(\.0) }
	}

	var athletes: [AthleteSelection] {
		lock.withLock { built.map(\.1) }
	}

	func append(_ credential: IntervalsCredential, _ athlete: AthleteSelection) {
		lock.withLock { built.append((credential, athlete)) }
	}
}
