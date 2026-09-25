import Foundation
import Testing

@testable import EnduragentCoach

@Suite struct FaultInjectingRecordLogTests {
	let phone = DeviceID(rawValue: "phone-a")
	let amsterdam: IANATimeZone

	init() throws {
		amsterdam = try #require(IANATimeZone(identifier: "Europe/Amsterdam"))
	}

	@Test func failNextAppendThrowsOnceThenPassesThrough() async throws {
		let log = FaultInjectingRecordLog(wrapping: InMemoryRecordLog(deviceId: phone))
		log.failNextAppend = true
		await #expect(throws: RecordStorageFault(operation: .append(.userMessage))) {
			try await log.append(
				record(wall: 1, body: .userMessage(sampleUser(chatId: .main, text: "lost"))))
		}
		#expect(log.failNextAppend == false)
		try await log.append(
			record(wall: 2, body: .userMessage(sampleUser(chatId: .main, text: "kept"))))
		let fetched = try await log.fetch(RecordQuery(kinds: [.userMessage]))
		#expect(fetched.map(\.ulid).count == 1)
	}

	@Test func failAppendsOfKindLeavesOtherKindsWritable() async throws {
		let log = FaultInjectingRecordLog(wrapping: InMemoryRecordLog(deviceId: phone))
		log.failAppends(ofKind: .assistantMessage)
		try await log.append(
			record(wall: 1, body: .userMessage(sampleUser(chatId: .main, text: "hi"))))
		await #expect(throws: RecordStorageFault(operation: .append(.assistantMessage))) {
			try await log.append(
				record(
					wall: 2, body: .assistantMessage(sampleAssistant(chatId: .main, text: "hello")))
			)
		}
		await #expect(throws: RecordStorageFault(operation: .append(.assistantMessage))) {
			try await log.append(
				record(
					wall: 3, body: .assistantMessage(sampleAssistant(chatId: .main, text: "again")))
			)
		}
		let users = try await log.fetch(RecordQuery(kinds: [.userMessage]))
		let assistants = try await log.fetch(RecordQuery(kinds: [.assistantMessage]))
		#expect(users.count == 1)
		#expect(assistants.isEmpty)
	}

	@Test func failFetchesThrowsUntilCleared() async throws {
		let log = FaultInjectingRecordLog(wrapping: InMemoryRecordLog(deviceId: phone))
		try await log.append(
			record(wall: 1, body: .userMessage(sampleUser(chatId: .main, text: "hi"))))
		log.failFetches = true
		await #expect(throws: RecordStorageFault(operation: .fetch)) {
			_ = try await log.fetch(RecordQuery(kinds: [.userMessage]))
		}
		log.failFetches = false
		#expect(try await log.fetch(RecordQuery(kinds: [.userMessage])).count == 1)
	}

	private func record(wall: Int64, body: RecordBody) -> AthleteRecord {
		AthleteRecord(
			ulid: ULID.generate(at: Date(timeIntervalSince1970: TimeInterval(wall))),
			deviceId: phone,
			hlc: HybridLogicalClock(wallMs: wall, logical: 0, deviceId: phone),
			timeZone: amsterdam,
			civilDate: "1998-06-13",
			body: body
		)
	}
}
