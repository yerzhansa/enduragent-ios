import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

@Suite(.timeLimit(.minutes(1))) struct CoachLedgerDedupeTests {
	@Test func syncedDeviceDuplicatesReachTheModelOnceWithoutChangingStoredRows() async throws {
		let phoneA = DeviceID(rawValue: "ledger-phone-a")
		let phoneB = DeviceID(rawValue: "ledger-phone-b")
		let store = InMemoryRecordLog(deviceId: phoneA)
		let original = storedRecord(
			device: phoneA, wall: 897_732_000_000, ulid: fixedUlid(1),
			account: testConnection.account,
			body: .synced(
				.ledgerEvent(
					LedgerEventBody(
						date: "1998-06-13", kind: .decision, text: "Keep Saturdays free.",
						source: .chat))))
		let duplicate = storedRecord(
			device: phoneB, wall: 897_732_060_000, ulid: fixedUlid(2),
			account: testConnection.account,
			body: .synced(
				.ledgerEvent(
					LedgerEventBody(
						date: "1998-06-13", kind: .decision, text: "  KEEP Saturdays   free.  ",
						source: .flush))))
		let distinct = storedRecord(
			device: phoneB, wall: 897_732_120_000, ulid: fixedUlid(3),
			account: testConnection.account,
			body: .synced(
				.ledgerEvent(
					LedgerEventBody(
						date: "1998-06-13", kind: .decision, text: "Ride easy on Sundays.",
						source: .chat))))
		try await seed(store, [duplicate, distinct, original])
		let storedQuery = RecordQuery(scope: Memory.snapshotScope)
		let before = try await store.fetch(storedQuery).records
		try #require(before.count == 3)
		let transport = FakeModelTransport()
		let coach = await makeCoach(transport: transport, store: store)
		let request = try await MemoryProbe.turn(
			[
				.toolCall(
					name: "memory_query",
					arguments: #"{"from":"1998-06-13","to":"1998-06-13"}"#)
			], saying: "What training decisions did I make?", expecting: "History recovered.",
			using: coach, transport: transport)
		let results = request.messages.filter { $0.role == .tool }
		let result = try #require(results.first)
		try #require(results.count == 1)
		let events = try MemoryProbe.events(in: MemoryProbe.text(in: result))
		let expectedEvents: [JSONValue] = [
			.object([
				"date": .string("1998-06-13"), "kind": .string("decision"),
				"text": .string("Keep Saturdays free."), "source": .string("chat"),
				"ts": .string("1998-06-13T10:00:00.000Z"),
			]),
			.object([
				"date": .string("1998-06-13"), "kind": .string("decision"),
				"text": .string("Ride easy on Sundays."), "source": .string("chat"),
				"ts": .string("1998-06-13T10:02:00.000Z"),
			]),
		]
		#expect(events == expectedEvents)
		for request in sent(.chatAttempt, by: transport) {
			let memory = try MemoryProbe.athleteData(in: MemoryProbe.systemText(in: request))
			#expect(memory.contains("## Athlete Memory\n"))
			#expect(try MemoryProbe.events(in: memory) == expectedEvents)
		}
		#expect(try await store.fetch(storedQuery).records == before)
	}
}
