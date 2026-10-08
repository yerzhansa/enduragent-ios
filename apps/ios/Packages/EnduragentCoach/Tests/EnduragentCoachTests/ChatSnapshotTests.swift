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
			let body: SyncedRecordBody
			switch index {
			case 2: body = sampleUser(chatId: .main, text: "Thursday?", turn: first)
			case 5: body = sampleUser(chatId: .main, text: "Friday?", turn: second)
			default:
				body = .reviewApplied(ReviewAppliedBody(chatId: .main, summary: .deleteWorkout))
			}
			records.append(
				storedRecord(
					device: store.deviceId, wall: Int64(index), ulid: fixedUlid(index),
					body: .synced(body)))
		}
		try await seed(store, records)
		let coach = await makeCoach(transport: FakeModelTransport(), store: store)
		let snapshot = try #require(await coach.currentSnapshot(.main))
		#expect(snapshot.notes[nil]?.map(\.id) == [fixedUlid(1)])
		#expect(snapshot.notes[first]?.map(\.id) == [fixedUlid(3), fixedUlid(4)])
		#expect(snapshot.notes[second]?.map(\.id) == [fixedUlid(6)])
	}

}
