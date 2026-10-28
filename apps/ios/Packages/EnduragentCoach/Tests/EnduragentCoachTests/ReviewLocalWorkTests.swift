import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

@Suite struct ReviewLocalWorkTests {
	let rig = DeskRig()
	let ada = FakeIntervalsClient(athlete: .cyclist(id: "i1001", name: "Ada Kovač", ftp: 250))
	let bo = FakeIntervalsClient(athlete: .cyclist(id: "i2002", name: "Bo Lind", ftp: 240))

	@Test(arguments: BoundHead.allCases)
	func theAthleteSwitchWaitsForAReviewThatIsNotCompletedOrCanceled(_ bound: BoundHead)
		async throws
	{
		let secrets = keyedSecrets()
		let coach = await coach(secrets)
		try await bound.save(in: rig, desk: coach.desk)

		let outcome = await coach.changeTraining(
			.replace(apiKey: "other-athlete", athlete: .keyOwner))

		let current = try #require(testConnection.resolvedAthlete)
		let new = try #require(IntervalsAthleteID(rawValue: "i2002"))
		if bound.holds {
			#expect(outcome == .refused(.differentAthlete(current: current, new: new)))
			#expect(try secrets.intervalsConnection() == testConnection)
		} else {
			guard case .replaced(let summary, _) = outcome else {
				Issue.record("expected the switch to go through, got \(outcome)")
				return
			}
			#expect(summary.athleteName == "Bo Lind")
			#expect(try secrets.intervalsConnection()?.resolvedAthlete == new)
		}
	}

	private func coach(_ secrets: any SecretStore) async -> Coach {
		let (ada, bo) = (ada, bo)
		return await consentingCoach(
			Coach(
				sport: .cycling,
				ports: CoachPorts(
					records: RecordStore(log: rig.store), secrets: secrets,
					models: .scripted(FakeModelTransport()),
					training: .fake { credential, _ in
						credential == .apiKey("other-athlete") ? bo : ada
					}, credits: .fake(FakeCreditsClient()), host: rig.host, clock: rig.clock,
					support: .inMemory(app: .fixture)),
				builtInModel: testModel, displayLocale: testDisplayLocale, coalescing: quickWindow))
	}
}
