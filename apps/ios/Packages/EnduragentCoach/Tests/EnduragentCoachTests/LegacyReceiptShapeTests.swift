import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

@Suite struct LegacyReceiptShapeTests {
	let clock = FixedClock(now: "1998-06-13T12:00:00+02:00", timeZone: "Europe/Amsterdam")
	let store = InMemoryRecordLog()
	let transport = FakeModelTransport()

	@Test func aPendingV1SoftJobSavesItsTriggeringTurn() async throws {
		try await seed(
			store,
			[
				record(4, body: legacyUser(chatId: .main, text: "Earlier question")),
				record(6, body: legacyReply(chatId: .main, text: "Earlier reply")),
				record(8, body: legacyUser(chatId: .main, text: "Triggering question")),
				record(9, body: legacyReply(chatId: .main, text: "Triggering reply")),
				record(
					10,
					body: .deviceLocal(
						.flushPending(
							FlushPendingBody(
								chatId: .main, messageUlids: [fixedUlid(4), fixedUlid(6)])))),
			])
		let coach = await makeCoach(transport: transport, store: store, clock: clock)
		try #require(await coach.transcript(.main).count == 4)
		#expect(await coach.resetAndSettle(in: .main) == .started(memory: .saved))
		let rows = sent(.memoryFlush, by: transport).flatMap(\.messages).map(\.unstampedContent)
		#expect(rows.filter { $0 == "Triggering question" }.count == 1)
		#expect(rows.filter { $0 == "Triggering reply" }.count == 1)
		#expect(rows.filter { $0 == "Earlier question" }.count == 1)
	}

	@Test(arguments: [false, true])
	func aPendingV1JobDoesNotHideOlderRowsImportedLater(drainedByModernBuild: Bool) async throws {
		try await seed(
			store,
			[
				record(4, body: legacyUser(chatId: .main, text: "Earlier question")),
				record(6, body: legacyReply(chatId: .main, text: "Earlier reply")),
				record(
					7,
					body: .deviceLocal(
						.flushPending(
							FlushPendingBody(
								chatId: .main, messageUlids: [fixedUlid(4), fixedUlid(6)])))),
				record(
					1, device: DeviceID(rawValue: "other-phone"),
					body: legacyUser(chatId: .main, text: "Imported Saturday")),
				record(
					2, device: DeviceID(rawValue: "other-phone"),
					body: legacyReply(chatId: .main, text: "Imported reply")),
			])
		if drainedByModernBuild {
			try await seed(
				store,
				[
					record(
						8,
						body: .deviceLocal(
							.flushSettled(
								FlushSettledBody(
									chatId: .main, job: FlushJobID(ulid: fixedUlid(7)),
									settlement: .nothingToSave))))
				])
		}
		let coach = await makeCoach(transport: transport, store: store, clock: clock)
		try #require(await coach.transcript(.main).count == 4)
		#expect(await coach.resetAndSettle(in: .main) == .started(memory: .saved))
		let rows = sent(.memoryFlush, by: transport).flatMap(\.messages).map(\.unstampedContent)
		#expect(rows.contains("Imported Saturday"))
		#expect(rows.contains("Imported reply"))
	}

	private func record(_ offset: Int, device: DeviceID? = nil, body: RecordBody)
		-> AthleteRecord
	{
		storedRecord(
			device: device ?? store.deviceId, wall: 899_164_800_000,
			logical: UInt32(offset), ulid: fixedUlid(offset), body: body)
	}
}
