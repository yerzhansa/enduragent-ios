import Foundation
import Testing

@testable import EnduragentCoach

@Suite struct FaultInjectingRecordLogTests {
	let phone = DeviceID(rawValue: "phone-a")

	@Test func failNextAppendThrowsOnceThenPassesThrough() async throws {
		let log = FaultInjectingRecordLog(wrapping: InMemoryRecordLog(deviceId: phone))
		log.failNextAppend = true
		await #expect(throws: RecordStorageFault(operation: .append(kinds: ["userMessage"]))) {
			try await log.append([record(wall: 1, text: "lost")], locality: .synced)
		}
		#expect(log.failNextAppend == false)
		try await log.append([record(wall: 2, text: "kept")], locality: .synced)
		let fetched = try await log.fetch(RecordQuery(scope: .synced([.userMessage]))).records
		#expect(fetched.map(messageText) == ["kept"])
	}

	@Test func failAppendsOfKindRejectsTheWholeBatchAndLeavesOtherKindsWritable() async throws {
		let log = FaultInjectingRecordLog(wrapping: InMemoryRecordLog(deviceId: phone))
		log.failAppends(ofKind: .turnSettled)
		try await log.append([record(wall: 1, text: "hi")], locality: .synced)
		let turn = TurnID(ulid: fixedUlid(1))
		let batch = [
			record(wall: 2, text: "question"),
			storedRecord(
				device: phone, wall: 3,
				body: .synced(sampleReply(chatId: .main, turn: turn, text: "hello"))),
		]
		await #expect(
			throws: RecordStorageFault(operation: .append(kinds: ["userMessage", "turnSettled"]))
		) {
			try await log.append(batch, locality: .synced)
		}
		let users = try await log.fetch(RecordQuery(scope: .synced([.userMessage]))).records
		let replies = try await log.fetch(RecordQuery(scope: .synced([.turnSettled]))).records
		#expect(users.map(messageText) == ["hi"])
		#expect(replies.isEmpty)
	}

	@Test func failFetchesThrowsUntilCleared() async throws {
		let log = FaultInjectingRecordLog(wrapping: InMemoryRecordLog(deviceId: phone))
		try await log.append([record(wall: 1, text: "hi")], locality: .synced)
		log.failFetches = true
		await #expect(throws: RecordStorageFault(operation: .fetch)) {
			_ = try await log.fetch(RecordQuery(scope: .synced([.userMessage])))
		}
		log.failFetches = false
		#expect(try await log.fetch(RecordQuery(scope: .synced([.userMessage]))).records.count == 1)
	}

	private func record(wall: Int64, text: String) -> AthleteRecord {
		storedRecord(
			device: phone, wall: wall, body: .synced(sampleUser(chatId: .main, text: text)))
	}
}
