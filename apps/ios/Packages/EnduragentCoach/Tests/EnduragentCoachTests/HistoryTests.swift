import Foundation
import Testing

@testable import EnduragentCoach

@Suite struct HistoryTests {
	let clock = FixedClock(now: "1998-06-13T12:00:00+02:00", timeZone: "Europe/Amsterdam")
	let transport = FakeModelTransport()
	let store = HistoryRecordLog()

	func coach() -> Coach {
		makeCoach(transport: transport, store: store, clock: clock)
	}

	func seedArchives() async throws {
		for index in 1...2 {
			let turn = TurnID(ulid: fixedUlid(index * 10))
			let boundary = fixedUlid(index * 10 + 2)
			try await seed(
				store,
				[
					storedRecord(
						device: store.deviceId, wall: Int64(index * 10), ulid: turn.ulid,
						body: .synced(sampleUser(chatId: .main, text: "Question \(index)", turn: turn))),
					storedRecord(
						device: store.deviceId, wall: Int64(index * 10 + 1),
						ulid: fixedUlid(index * 10 + 1),
						body: .synced(sampleReply(chatId: .main, turn: turn, text: "Archived reply \(index)"))),
					storedRecord(
						device: store.deviceId, wall: Int64(index * 10 + 2), ulid: boundary,
						body: .synced(
							.windowStart(
								WindowStartBody(
									chatId: .main, firstIncludedUlid: boundary,
									reason: .reset(ResetID(ulid: boundary)))))),
				])
		}
	}

	@Test func historyListCarriesNoReplyText() async throws {
		try await seedArchives()
		let history = try await coach().history()
		#expect(history.count == 2)
		#expect(!String(reflecting: history).contains("Archived reply"))
		#expect(await store.replyReads.isEmpty)
		#expect(transport.requests.isEmpty)
	}
}

actor HistoryRecordLog: RecordLog {
	private let wrapped = InMemoryRecordLog()
	private(set) var replyReads: [AthleteRecord] = []

	nonisolated var deviceId: DeviceID { wrapped.deviceId }
	nonisolated var imports: AsyncStream<Void> { wrapped.imports }

	func append(_ batch: [AthleteRecord], locality: RecordLocality) async throws {
		try await wrapped.append(batch, locality: locality)
	}

	func latest(locality: RecordLocality, writtenBy: DeviceID) async throws -> RecordCursor? {
		try await wrapped.latest(locality: locality, writtenBy: writtenBy)
	}

	func fetch(_ query: RecordQuery) async throws -> RecordPage {
		let page = try await wrapped.fetch(query)
		replyReads += page.records.filter {
			switch $0.body {
			case .synced(.turnSettled), .legacy(.assistantMessage): true
			default: false
			}
		}
		return page
	}
}
