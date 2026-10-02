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
			body: .synced(
				.ledgerEvent(
					LedgerEventBody(
						date: "1998-06-13", kind: .decision, text: "Keep Saturdays free.",
						source: .chat))))
		let duplicate = storedRecord(
			device: phoneB, wall: 897_732_060_000, ulid: fixedUlid(2),
			body: .synced(
				.ledgerEvent(
					LedgerEventBody(
						date: "1998-06-13", kind: .decision, text: "  KEEP Saturdays   free.  ",
						source: .flush))))
		let distinct = storedRecord(
			device: phoneB, wall: 897_732_120_000, ulid: fixedUlid(3),
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
		transport.respond = ScriptedReply.sequence(
			[
				.toolCall(
					name: "memory_query",
					arguments: #"{"from":"1998-06-13","to":"1998-06-13"}"#),
				.finish(reason: .toolCalls), .text("History recovered."), .finish(reason: .stop),
			], otherwise: { _ in ScriptedReply([.finish(reason: .stop)]) })
		#expect(
			replyText(try await coach.sendAndSettle("What training decisions did I make?"))
				== "History recovered.")
		let request = try #require(sent(.chatAttempt, by: transport).last)
		let results = request.messages.filter { $0.role == .tool }
		let result = try #require(results.first)
		try #require(results.count == 1)
		let payload = try JSONValue.parse(result.content)
		#expect(payload.objectFields["untrusted_data"]?.stringValue == UntrustedEnvelope.banner)
		let history = try #require(payload.objectFields["data"]?.stringValue)
		let events = try history.split(separator: "\n").filter { $0.hasPrefix("event: ") }.map {
			try JSONValue.parse(String($0.dropFirst("event: ".count)))
		}
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
			let system = try #require(request.messages.first { $0.role == .system }).content
			let open = try #require(system.range(of: PromptAssembly.athleteDataOpen))
			let close = try #require(system.range(of: PromptAssembly.athleteDataClose))
			try #require(open.upperBound <= close.lowerBound)
			let memory = String(system[open.upperBound..<close.lowerBound])
			#expect(memory.contains("## Athlete Memory\n"))
			let memoryEvents = try memory.split(separator: "\n").filter {
				$0.hasPrefix("event: ")
			}.map {
				try JSONValue.parse(String($0.dropFirst("event: ".count)))
			}
			#expect(memoryEvents == expectedEvents)
		}
		#expect(try await store.fetch(storedQuery).records == before)
	}
}
