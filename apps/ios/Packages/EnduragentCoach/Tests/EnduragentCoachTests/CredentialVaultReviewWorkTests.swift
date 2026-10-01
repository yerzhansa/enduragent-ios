import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

extension CredentialVaultTests {
	@Test(arguments: [false, true])
	func inFlightReviewBlocksAthleteSwitch(redisplay: Bool) async throws {
		let gate = ReviewGate()
		let secrets = keyedSecrets()
		let ada = self.ada
		let bo = self.bo
		let held = GatedReviewIntervals(base: ada, gate: gate)
		let coach = await consentingCoach(
			Coach(
				sport: .cycling,
				ports: CoachPorts(
					records: RecordStore(log: records), secrets: secrets,
					models: .scripted(transport),
					training: .fake { credential, _ in
						if credential == .apiKey("other-athlete") { return bo }
						return held
					},
					credits: .fake(FakeCreditsClient()), host: ImmediateExecutionHost(),
					clock: clock),
				builtInModel: testModel, deviceLanguage: .en, coalescing: quickWindow))
		let review = try await proposeRide(on: coach)
		#expect(await coach.decide(.presented(review.ref), in: .main) == .presentationRecorded)
		let token = try #require(await coach.currentSnapshot(.main)?.review?.token)
		await gate.arm()
		let approval = Task { await coach.decide(.approve(token), in: .main) }
		#expect(await gate.waitUntilEntered())
		let rows = try await records.fetch(ProposalPolicy.proposalQuery(.main))
		#expect(
			UnionMerge.pendingProposalRecord(rows.records, chatId: .main, now: clock.now) == nil)
		if redisplay {
			#expect(await coach.decide(.showAgain(review.ref), in: .main) == .staleControl)
		}
		let current = try #require(IntervalsAthleteID(rawValue: "i1001"))
		let new = try #require(IntervalsAthleteID(rawValue: "i2002"))
		let outcome = await coach.changeTraining(
			.replace(apiKey: "other-athlete", athlete: .keyOwner))
		#expect(outcome == .refused(.differentAthlete(current: current, new: new)))
		#expect(try secrets.intervalsConnection() == testConnection)
		let repeated = await coach.changeTraining(
			.replace(apiKey: "other-athlete", athlete: .keyOwner))
		#expect(repeated == .refused(.differentAthlete(current: current, new: new)))
		#expect(try secrets.intervalsConnection() == testConnection)
		await gate.release()
		let applied = await approval.value
		guard case .applied = applied else {
			Issue.record("expected the approved workout to finish, got \(applied)")
			return
		}
		#expect(ada.calls.filter { if case .createEvent = $0 { true } else { false } }.count == 1)
		let replacement = await coach.changeTraining(
			.replace(apiKey: "other-athlete", athlete: .keyOwner))
		guard case .replaced(_, .changed?) = replacement else {
			Issue.record("expected the athlete switch after approval completes, got \(replacement)")
			return
		}
		#expect(try secrets.intervalsConnection()?.credential == .apiKey("other-athlete"))
	}
}
