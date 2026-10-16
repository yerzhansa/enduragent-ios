import EnduragentCoachFixtures
import Foundation
import Synchronization
import Testing

@testable import EnduragentCoach

extension TurnRunnerTests {
	@Test func theNextSendReadsMemoryWrittenByATool() async throws {
		transport.respond = ScriptedReply.sequence(
			[
				.toolCall(
					name: "memory_write",
					arguments:
						#"{"type":"memory","section":"schedule","content":"Saturday group ride"}"#),
				.finish(reason: .toolCalls), .text("Saved."), .finish(reason: .stop),
				.text("Saturday is on."), .finish(reason: .stop),
			], otherwise: transport.respond)
		let coach = await EnduragentCoachTests.makeCoach(
			transport: transport, store: store, clock: clock)
		#expect(replyText(try await coach.sendAndSettle("Remember Saturdays")) == "Saved.")
		#expect(replyText(try await coach.sendAndSettle("Is Saturday on?")) == "Saturday is on.")
		let first = try #require(transport.requests.first)
		let last = try #require(transport.requests.last)
		#expect(!first.messages[0].content.contains("Saturday group ride"))
		#expect(last.messages[0].content.contains("Saturday group ride"))
		#expect(
			last.messages.dropFirst().dropLast().map(\.unstampedContent) == [
				"Remember Saturdays", "Saved.",
			])
	}

	@Test func oneSendReadsMemoryOnce() async throws {
		try await seedHistory(store, clock: clock, turns: 1, tokens: 40)
		try await seed(
			store,
			[
				storedRecord(
					device: store.deviceId, wall: 1, ulid: fixedUlid(1),
					body: .synced(
						.memorySection(
							MemorySectionBody(
								name: SectionName(rawValue: "schedule"),
								content: "Saturday group ride"))))
			])
		let recording = BatchRecordingLog(inner: store)
		let readsAtRequest = Mutex<[RecordQuery.Scope]>([])
		let responding = FakeModelTransport { _ in
			readsAtRequest.withLock { $0 = recording.reads }
			return ScriptedReply([.text("Saturday is on."), .finish(reason: .stop)])
		}
		let coach = await EnduragentCoachTests.makeCoach(
			transport: responding, store: recording, clock: clock)
		let settled = try await coach.sendAndSettle("Is Saturday on?")
		#expect(replyText(settled) == "Saturday is on.")
		let memoryScope = RecordQuery.Scope.synced([
			.memorySection, .dailyNote, .ledgerEvent, .journal, .compactionSummary,
		])
		#expect(readsAtRequest.withLock { $0.filter { $0 == memoryScope }.count } == 1)
		#expect(
			readsAtRequest.withLock { $0.filter { $0 == ConversationFold.syncedScope }.count } == 1)
		#expect(responding.requests.count == 1)
		let request = try #require(responding.requests.first)
		#expect(request.messages.first?.content.contains("Saturday group ride") == true)
		#expect(
			request.messages.dropFirst().dropLast().map(\.unstampedContent) == [
				"Question 0", "Answer 0 " + String(repeating: "w", count: 133),
			])
		#expect(request.messages.last?.content.hasPrefix("Is Saturday on?\nCurrent time:") == true)
	}

}
