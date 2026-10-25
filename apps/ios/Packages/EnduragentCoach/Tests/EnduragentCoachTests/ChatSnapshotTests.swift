import EnduragentCoachFixtures
import Testing

@testable import EnduragentCoach

struct ChatSnapshotTests {
	@Test func reviewNotesAreGroupedBeforeAndAfterTurns() async throws {
		let store = InMemoryRecordLog()
		let first = TurnID(ulid: fixedUlid(2))
		let second = TurnID(ulid: fixedUlid(5))
		var records: [AthleteRecord] = []
		for index in 1...6 {
			let body: RecordBody
			switch index {
			case 2: body = .synced(sampleUser(chatId: .main, text: "Thursday?", turn: first))
			case 5: body = .synced(sampleUser(chatId: .main, text: "Friday?", turn: second))
			default:
				body = .legacy(
					.reviewApplied(ReviewAppliedBody(chatId: .main, summary: .deleteWorkout)))
			}
			records.append(
				storedRecord(
					device: store.deviceId, wall: Int64(index), ulid: fixedUlid(index),
					body: body))
		}
		try await seed(store, records)
		let coach = await makeCoach(transport: FakeModelTransport(), store: store)
		let snapshot = try #require(await coach.currentSnapshot(.main))
		#expect(snapshot.notes[nil]?.map(\.id) == [fixedUlid(1)])
		#expect(snapshot.notes[first]?.map(\.id) == [fixedUlid(3), fixedUlid(4)])
		#expect(snapshot.notes[second]?.map(\.id) == [fixedUlid(6)])
	}

	@Test func theObservedSnapshotCarriesThePlanCardAndThenItsArmedControls() async throws {
		let turns = PlanTurns()
		let coach = await turns.coach()
		let observed = await coach.observe(.main)

		_ = try await turns.reply(after: [[turns.save(PlanTurns.baseBuild)]], on: coach)

		let waiting = try #require(
			try await firstSnapshot(in: observed, within: .hangGuard) {
				$0.plans.map(\.state) == [.waiting(.unarmed)]
			})
		let card = try #require(waiting.plans.first)
		#expect(card.summary.name == "Base Build")
		#expect(await coach.decide(.presented(card.ref), in: .main) == .presented)
		let armed = try #require(
			try await firstSnapshot(in: observed, within: .hangGuard) {
				PlanTurns.token(of: $0.plans.first) != nil
			})
		#expect(armed.plans.map(\.ref) == [card.ref])
		#expect(armed != waiting)
	}
}
