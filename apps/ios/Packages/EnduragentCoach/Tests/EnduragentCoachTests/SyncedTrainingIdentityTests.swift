import EnduragentCoachFixtures
import Foundation
import Security
import Testing

@testable import EnduragentCoach

@Suite struct SyncedTrainingIdentityTests {
	let fixture: CredentialVaultTests
	let backing = FixtureSecretStoreBacking()
	let secrets: ICloudKeychainStore
	let peer: FixtureTrainingPeer

	init() throws {
		fixture = try CredentialVaultTests()
		secrets = keyedSecrets(backing: backing)
		peer = FixtureTrainingPeer(
			secrets: ICloudKeychainStore(backing: backing), athleteA: fixture.ada)
	}

	@Test func resumeResolvesPeerReplacement() async throws {
		let coach = await open()
		_ = try await coach.refreshedStatus()
		let statuses = await coach.observeStatus()
		await coach.lifecycle(.enteredBackground)
		try peer.replace(.athleteB)
		await coach.lifecycle(.becameActive)
		let status = try #require(
			try await statuses.status { $0.trainingAccount?.athlete == "i2002" })
		#expect(status.training.summary?.athleteName == "Bo Lind")
		try await assertTurnUsesBo(coach)
	}

	@Test func foregroundTurnResolvesPeerReplacement() async throws {
		let coach = await open()
		_ = try await coach.refreshedStatus()
		let statuses = await coach.observeStatus()
		try peer.replace(.athleteB)
		try await assertTurnUsesBo(coach)
		let status = try #require(
			try await statuses.status { $0.trainingAccount?.athlete == "i2002" })
		#expect(status.training.summary?.athleteName == "Bo Lind")
	}

	@Test(arguments: [false, true], [false, true])
	func lateProfileCannotOverwritePeerReplacement(reusesConnectionID: Bool, localReplacement: Bool)
		async throws
	{
		let coach = await open()
		let held = fixture.ada.hold(.profile)
		let oldRead = Task {
			if localReplacement {
				_ = await coach.changeTraining(
					.replace(apiKey: "fixture-held-a-key", athlete: .keyOwner))
			} else {
				await coach.lifecycle(.becameActive)
			}
		}
		defer { Task { await held.release() } }
		defer { oldRead.cancel() }
		try #require(
			try await beforeDeadline(within: .hangGuard) { await held.waitUntilEntered() } != nil)
		if reusesConnectionID {
			try ICloudKeychainStore(backing: backing).storeIntervalsConnection(
				IntervalsConnection(
					id: testConnection.id,
					credential: .apiKey(FixtureTrainingPeer.Key.athleteB.secret),
					selection: .keyOwner, resolvedAthlete: testConnection.resolvedAthlete))
		} else {
			try peer.replace(.athleteB)
		}
		try await assertTurnUsesBo(coach)
		let replacement = try #require(try secrets.intervalsConnection())
		await held.release()
		try #require(try await beforeDeadline(within: .hangGuard) { await oldRead.value } != nil)
		#expect(try secrets.intervalsConnection() == replacement)
		#expect(replacement.resolvedAthlete?.rawValue == "i2002")
		let status = try await coach.observedStatus()
		#expect(status.training.summary?.athleteName == "Bo Lind")
		#expect(status.trainingAccount?.athlete == "i2002")
	}

	func open() async -> Coach {
		await consentingCoach(
			Coach(
				sport: .cycling,
				ports: CoachPorts(
					records: RecordStore(log: fixture.records), secrets: secrets,
					models: .scripted(fixture.transport),
					training: .fake { credential, _ in peer.client(for: credential) },
					credits: .fake(FakeCreditsClient()), host: ImmediateExecutionHost(),
					clock: fixture.clock, support: .inMemory(app: .fixture)),
				builtInModel: testModel, displayLocale: testDisplayLocale, coalescing: quickWindow))
	}

	func assertTurnUsesBo(_ coach: Coach) async throws {
		fixture.transport.respond = ScriptedReply.sequence(
			[
				.toolCall(name: ToolName.intervalsFetchAthlete.rawValue, arguments: "{}"),
				.finish(reason: .toolCalls), .text("Profile read."), .finish(reason: .stop),
			], otherwise: fixture.transport.respond)
		_ = try await coach.sendAndSettle("Read my training profile")
		let claims = try await fixture.records.fetch(
			RecordQuery(scope: .deviceLocal([.turnClaim]), chatId: "main"))
		#expect(claims.records.last?.account.athlete == "i2002")
		let request = try #require(fixture.transport.requests.last)
		let results = request.messages.filter { $0.role == .tool }.map(\.content).joined()
		#expect(results.contains("Bo Lind"))
		#expect(!results.contains("Ada Kovač"))
		#expect(peer.athleteB.count(of: .profile) >= 2)
	}
}

extension TrainingAccount {
	var athlete: String? {
		guard case .intervals(_, let athlete) = self else { return nil }
		return athlete?.rawValue
	}
}

extension TrainingStatus {
	var summary: IntervalsSummary? {
		guard case .connected(let summary, _) = self else { return nil }
		return summary
	}
}
