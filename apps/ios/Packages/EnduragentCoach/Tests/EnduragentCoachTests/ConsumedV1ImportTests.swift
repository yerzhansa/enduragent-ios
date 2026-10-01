import Foundation
import Testing

@testable import EnduragentCoach

@Suite struct ConsumedV1ImportTests {
	let clock = FixedClock(now: "1998-06-13T12:00:00+02:00", timeZone: "Europe/Amsterdam")
	let store = InMemoryRecordLog()
	let transport = FakeModelTransport()

	@Test(arguments: [(true, false), (false, false), (false, true)])
	func aConsumedNonemptyV1ReceiptDoesNotHideLaterImports(
		legacy: Bool, belowListedMaximum: Bool
	) async throws {
		let job = FlushJobID(ulid: receiptID(20))
		try await seed(
			store,
			[
				record(4, body: legacyUser(chatId: .main, text: "Already extracted question")),
				record(6, body: legacyReply(chatId: .main, text: "Already extracted reply")),
				record(7, body: legacyUser(chatId: .main, text: "Earlier question two")),
				record(8, body: legacyReply(chatId: .main, text: "Earlier reply two")),
				record(9, body: legacyUser(chatId: .main, text: "Earlier question three")),
				record(10, body: legacyReply(chatId: .main, text: "Earlier reply three")),
				record(16, body: legacyUser(chatId: .main, text: "Extracted triggering question")),
				record(17, body: legacyReply(chatId: .main, text: "Extracted triggering reply")),
				record(
					20,
					body: .deviceLocal(
						.flushPending(
							FlushPendingBody(
								chatId: .main, messageUlids: [4, 6, 7, 8, 9, 10].map(receiptID))))),
				record(
					23,
					body: .synced(
						.provenance(
							ProvenanceBody(
								key: MemoryFlushPolicy.consumedFlushKeyPrefix + job.ulid.rawValue,
								garmin: false, nonGarmin: false, unknown: false,
								contentSha256: sha256Hex(job.ulid.rawValue))))),
			])
		if !belowListedMaximum {
			try await seed(
				store,
				[
					record(
						21,
						body: .legacy(
							.windowStartV1(chatId: .main, firstIncludedUlid: receiptID(7))))
				])
		}
		let ledger = Ledger(log: store, clock: clock, diagnostics: DiagnosticsLog(clock: clock))
		let beforeImport = try await ledger.conversation(.main)
		let alreadyExtracted = [
			"Already extracted question", "Already extracted reply",
			"Earlier question two", "Earlier reply two", "Earlier question three",
			"Earlier reply three",
			"Extracted triggering question", "Extracted triggering reply",
		]
		try #require(
			beforeImport.current.messages.map(\.text)
				== Array(alreadyExtracted.dropFirst(belowListedMaximum ? 0 : 2)))
		let originalJobs = try await ledger.flushJobs(in: try await ledger.conversation(.main))
		try #require(originalJobs.count == 1)
		try #require(originalJobs.allSatisfy { $0.saved })
		let first = belowListedMaximum ? 1 : 12
		let turn = TurnID(ulid: receiptID(first))
		let foreign = DeviceID(rawValue: "offline-phone")
		try await seed(
			store,
			[
				record(
					first, device: foreign,
					body: legacy
						? legacyUser(chatId: .main, text: "Never extracted imported question")
						: .synced(
							sampleUser(
								chatId: .main, text: "Never extracted imported question", turn: turn
							))),
				record(
					first + 1, device: foreign,
					body: legacy
						? legacyReply(chatId: .main, text: "Never extracted imported reply")
						: .synced(
							sampleReply(
								chatId: .main, turn: turn, text: "Never extracted imported reply"))),
			])
		let coach = await makeCoach(transport: transport, store: store, clock: clock)
		try #require(await coach.transcript(.main).count == (belowListedMaximum ? 10 : 8))
		try #require(sent(.memoryFlush, by: transport).isEmpty)
		#expect(await coach.startNewConversation(in: .main) == .started(memory: .saved))
		let extracted = sent(.memoryFlush, by: transport).flatMap(\.messages).map(
			\.unstampedContent)
		#expect(extracted.filter { $0 == "Never extracted imported question" }.count == 1)
		#expect(extracted.filter { $0 == "Never extracted imported reply" }.count == 1)
		let afterReset = try await ledger.conversation(.main)
		#expect(afterReset.current.messages.isEmpty)
		#expect(
			afterReset.segments.dropLast().flatMap(\.messages).count
				== (belowListedMaximum ? 10 : 8))
	}

	@Test func aConsumedV1ReceiptCoversLegacyRowsBetweenItsListedRows() async throws {
		let job = FlushJobID(ulid: receiptID(20))
		try await seed(
			store,
			[
				record(4, body: legacyUser(chatId: .main, text: "First listed question")),
				record(6, body: legacyReply(chatId: .main, text: "First listed reply")),
				record(7, body: legacyUser(chatId: .main, text: "Merged question")),
				record(8, body: legacyReply(chatId: .main, text: "Merged reply")),
				record(9, body: legacyUser(chatId: .main, text: "Last listed question")),
				record(10, body: legacyReply(chatId: .main, text: "Last listed reply")),
				record(
					20,
					body: .deviceLocal(
						.flushPending(
							FlushPendingBody(
								chatId: .main, messageUlids: [4, 6, 9, 10].map(receiptID))))),
				record(
					23,
					body: .synced(
						.provenance(
							ProvenanceBody(
								key: MemoryFlushPolicy.consumedFlushKeyPrefix + job.ulid.rawValue,
								garmin: false, nonGarmin: false, unknown: false,
								contentSha256: sha256Hex(job.ulid.rawValue))))),
			])
		let coach = await makeCoach(transport: transport, store: store, clock: clock)
		try #require(await coach.transcript(.main).count == 6)
		#expect(await coach.startNewConversation(in: .main) == .started(memory: .saved))
		#expect(sent(.memoryFlush, by: transport).isEmpty)
	}

	private func record(_ offset: Int, device: DeviceID? = nil, body: RecordBody)
		-> AthleteRecord
	{
		storedRecord(
			device: device ?? store.deviceId,
			wall: Int64(
				clock.now.addingTimeInterval(Double(offset) - 60).timeIntervalSince1970 * 1_000),
			ulid: receiptID(offset), body: body)
	}

	private func receiptID(_ offset: Int) -> ULID {
		let timestamp = ULID.generate(at: clock.now.addingTimeInterval(Double(offset) - 60))
			.rawValue.prefix(10)
		guard let id = ULID(rawValue: timestamp + "0000000000000000") else {
			preconditionFailure("The timestamp and suffix form a ULID")
		}
		return id
	}
}
