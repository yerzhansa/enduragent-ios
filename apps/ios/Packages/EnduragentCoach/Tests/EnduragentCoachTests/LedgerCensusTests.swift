import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

@Suite struct LedgerCensusTests {
	let clock = FixedClock(now: "1998-06-13T08:00:00+02:00", timeZone: "Europe/Amsterdam")
	let phone = DeviceID(rawValue: "phone-a")

	@Test func theCensusCountsEachKindAndTheSkippedRows() async throws {
		let store = try await seededStore()
		let ledger = Ledger(
			log: SkippingLog(
				base: store,
				skipped: [
					.malformed(kind: "userMessage", ulid: "row-1"),
					.newerKind(kind: "futureKind", ulid: "row-2"),
				],
				skippedLocal: [.newerVersion(kind: "turnClaim", version: 9, ulid: "row-3")]),
			chain: store, clock: clock, diagnostics: DiagnosticsLog(clock: clock))
		#expect(
			await ledger.census()
				== .counted(
					synced: [.userMessage: 2, .dailyNote: 1], local: [.replyObserved: 1],
					legacy: [.userMessage: 1, .assistantMessage: 1], skipped: 3))
	}

	@Test func anUnreadableStoreIsCountedAsUnavailable() async throws {
		let store = InMemoryRecordLog(deviceId: phone)
		let ledger = Ledger(
			log: SkippingLog(base: store, unreadable: true), chain: store, clock: clock,
			diagnostics: DiagnosticsLog(clock: clock))
		#expect(await ledger.census() == .unavailable(.unavailable))
	}

	@Test func theRecordSyncProbeCountsEachKindByItsName() async throws {
		let store = try await seededStore()
		let coach = await makeCoach(
			transport: FakeModelTransport(), store: store, clock: clock, consent: false)
		let snapshot = try await coach.recordSyncProbe().snapshot()
		#expect(
			snapshot.counts == [
				RecordSyncCount(kind: "assistantMessage", count: 1),
				RecordSyncCount(kind: "dailyNote", count: 1),
				RecordSyncCount(kind: "replyObserved", count: 1),
				RecordSyncCount(kind: "userMessage", count: 3),
			])
		#expect(snapshot.rows.count == 6)
		#expect(snapshot.skipped == 0)
	}

	private func seededStore() async throws -> InMemoryRecordLog {
		let store = InMemoryRecordLog(deviceId: phone)
		try await seed(
			store,
			[
				storedRecord(
					device: phone, wall: 1, body: .synced(sampleUser(chatId: .main, text: "a"))),
				storedRecord(
					device: phone, wall: 2, body: .synced(sampleUser(chatId: .main, text: "b"))),
				storedRecord(
					device: phone, wall: 3, body: .synced(.dailyNote(DailyNoteBody(note: "n")))),
				storedRecord(device: phone, wall: 4, body: .deviceLocal(sampleLocal())),
				storedRecord(device: phone, wall: 5, body: legacyUser(chatId: .main, text: "c")),
				storedRecord(device: phone, wall: 6, body: legacyReply(chatId: .main, text: "d")),
			])
		return store
	}
}

struct SkippingLog: RecordLog {
	let base: any RecordLog
	var skipped: [SkippedRow] = []
	var skippedLocal: [SkippedRow] = []
	var unreadable = false

	var deviceId: DeviceID { base.deviceId }

	func append(_ batch: [AthleteRecord], locality: RecordLocality) async throws {
		try await base.append(batch, locality: locality)
	}

	func fetch(_ query: RecordQuery) async throws -> RecordPage {
		guard !unreadable else { throw CocoaError(.fileReadCorruptFile) }
		let page = try await base.fetch(query)
		switch query.scope {
		case .everySynced: return RecordPage(records: page.records, skipped: skipped)
		case .everyDeviceLocal: return RecordPage(records: page.records, skipped: skippedLocal)
		default: return page
		}
	}

	func latest(locality: RecordLocality, writtenBy: DeviceID) async throws -> RecordCursor? {
		try await base.latest(locality: locality, writtenBy: writtenBy)
	}

	var imports: AsyncStream<Void> { base.imports }
}
