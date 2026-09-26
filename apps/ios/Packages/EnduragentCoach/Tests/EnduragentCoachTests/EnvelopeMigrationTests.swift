import Foundation
import SQLite3
import SwiftData
import Testing

@testable import EnduragentCoach

@Suite struct EnvelopeMigrationTests {
	let phoneA = DeviceID(rawValue: "phone-a")
	let clock = FixedClock(now: "1998-06-16T08:00:00+02:00", timeZone: "Europe/Ljubljana")

	@Test func v1RowsDecodeAsLegacyBodies() async throws {
		let store = try V1Store.materialize()
		let log = try store.open(deviceId: phoneA)
		let synced = try await log.fetch(RecordQuery(scope: .everySynced))
		#expect(synced.skipped.isEmpty)
		#expect(synced.records.count == 13)
		#expect(
			kinds(synced.records) == [
				"userMessage", "assistantMessage", "userMessage", "assistantMessage", "windowStart",
				"compactionSummary", "memorySection", "dailyNote", "ledgerEvent", "journal",
				"provenance", "coachReplyLanguage", "planningDevice",
			])
		#expect(synced.records.allSatisfy { $0.cause == .legacy && $0.account == .unconnected })
		#expect(
			synced.records[0].body
				== .legacy(
					.userMessageV1(
						chatId: .main, athleteText: "What did my week look like?", slash: nil)))
		#expect(
			synced.records[2].body
				== .legacy(.userMessageV1(chatId: .main, athleteText: "/review", slash: .review)))
		#expect(
			synced.records[4].body
				== .legacy(
					.windowStartV1(chatId: .main, firstIncludedUlid: store.manifest.questionB)))
		guard case .synced(.ledgerEvent(let event)) = synced.records[8].body else {
			Issue.record("expected a ledger event")
			return
		}
		#expect(event.date == "1998-06-10")
		#expect(event.text == "Keep Saturdays free.")
		let local = try await log.fetch(RecordQuery(scope: .everyDeviceLocal))
		#expect(local.skipped.isEmpty)
		#expect(kinds(local.records) == ["pendingProposal", "proposalCleared", "flushPending"])
	}

	@Test func v1TranscriptFoldsWithLegacyRepliesSettled() async throws {
		let store = try V1Store.materialize()
		let log = try store.open(deviceId: phoneA)
		let page = try await log.fetch(
			RecordQuery(scope: ConversationFold.syncedScope, chatId: .main))
		let conversation = ConversationFold.fold(chat: .main, synced: page.records, device: phoneA)
		#expect(
			conversation.current.messages.map(\.text) == [
				"What did my week look like?", "Your week: two rides, 3 h 10 min.", "/review",
				"Saturday group ride summary.",
			])
		#expect(
			conversation.current.promptHistory(excluding: nil).messages.map(\.text) == [
				"/review", "Saturday group ride summary.",
			])
	}

	@Test func upgradedStoreAcceptsEnvelopeV2Writes() async throws {
		let store = try V1Store.materialize()
		let log = try store.open(deviceId: phoneA)
		let ledger = Ledger(log: log, clock: clock, diagnostics: DiagnosticsLog(clock: clock))
		let turn = TurnID(ulid: await ledger.nextULID())
		_ = try await ledger.commit(
			synced: [
				sampleUser(chatId: .main, text: "after the upgrade", turn: turn),
				sampleReply(chatId: .main, turn: turn, text: "Noted."),
			],
			stamp: testStamp())
		let page = try await ledger.read(
			RecordQuery(scope: ConversationFold.syncedScope, chatId: .main))
		let conversation = ConversationFold.fold(chat: .main, synced: page.records, device: phoneA)
		#expect(
			conversation.current.messages.map(\.text).suffix(2) == ["after the upgrade", "Noted."])
		let byTurn = try await log.fetch(
			RecordQuery(scope: .synced([.userMessage, .turnSettled]), turn: turn)
		).records
		#expect(kinds(byTurn) == ["userMessage", "turnSettled"])
	}

	@Test func unknownKindBecomesSkippedRowNotAThrow() async throws {
		let store = try V1Store.materialize()
		let log = try store.open(deviceId: phoneA)
		try store.insertRaw(kind: "hologram", bodyVersion: 2, ulid: "01HGRAM0000000000000000000")
		let page = try await log.fetch(RecordQuery(scope: .everySynced))
		#expect(page.skipped == [.newerKind(kind: "hologram", ulid: "01HGRAM0000000000000000000")])
		#expect(page.records.count == 13)
	}

	@Test func newerBodyVersionBecomesSkippedRow() async throws {
		let store = try V1Store.materialize()
		let log = try store.open(deviceId: phoneA)
		try store.insertRaw(
			kind: "userMessage", bodyVersion: 99, ulid: "01NEWVERS00000000000000000")
		let page = try await log.fetch(RecordQuery(scope: .synced([.userMessage])))
		#expect(
			page.skipped == [
				.newerVersion(kind: "userMessage", version: 99, ulid: "01NEWVERS00000000000000000")
			])
		#expect(page.records.isEmpty)
		let withLegacy = try await log.fetch(
			RecordQuery(scope: .synced([.userMessage], includeLegacy: [.userMessage])))
		#expect(withLegacy.records.count == 2)
		#expect(withLegacy.skipped.count == 1)
	}
}

struct V1Store {
	struct Manifest: Decodable {
		let question: ULID
		let reply: ULID
		let questionB: ULID
		let replyB: ULID
		let window: ULID
	}

	let root: URL
	let manifest: Manifest

	static func materialize() throws -> V1Store {
		let root = FileManager.default.temporaryDirectory.appending(
			path: "enduragent-v1-\(UUID().uuidString)", directoryHint: .isDirectory)
		try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
		for name in ["synced", "local"] {
			let sql = try String(contentsOf: try fixture(name, "sql"), encoding: .utf8)
			try restore(sql, into: root.appending(path: "\(name).store"))
		}
		let manifest = try JSONDecoder().decode(
			Manifest.self, from: try Data(contentsOf: try fixture("manifest", "json")))
		return V1Store(root: root, manifest: manifest)
	}

	func open(deviceId: DeviceID) throws -> SwiftDataRecordLog {
		SwiftDataRecordLog(
			deviceId: deviceId,
			synced: try ModelContainerHandle.withoutCloudKit(
				storeURL: root.appending(path: "synced.store")),
			local: try ModelContainerHandle.withoutCloudKit(
				storeURL: root.appending(path: "local.store"))
		)
	}

	func insertRaw(kind: String, bodyVersion: Int, ulid: String) throws {
		let handle = try ModelContainerHandle.withoutCloudKit(
			storeURL: root.appending(path: "synced.store"))
		let context = ModelContext(handle.container)
		let row = try StoredAthleteRecord(
			record: storedRecord(
				device: DeviceID(rawValue: "phone-a"), wall: 999,
				body: .synced(.dailyNote(DailyNoteBody(note: "raw")))))
		context.insert(row)
		row.kind = kind
		row.bodyVersion = bodyVersion
		row.ulid = ulid
		try context.save()
	}

	private static func fixture(_ name: String, _ ext: String) throws -> URL {
		try #require(
			Bundle.module.url(
				forResource: name, withExtension: ext, subdirectory: "Fixtures/v1-records"))
	}

	private static func restore(_ sql: String, into url: URL) throws {
		var handle: OpaquePointer?
		guard sqlite3_open(url.path, &handle) == SQLITE_OK, let database = handle else {
			throw V1StoreFailure(step: "open")
		}
		defer { sqlite3_close(database) }
		var message: UnsafeMutablePointer<CChar>?
		guard sqlite3_exec(database, sql, nil, nil, &message) == SQLITE_OK else {
			let detail = message.map { String(cString: $0) } ?? "exec"
			sqlite3_free(message)
			throw V1StoreFailure(step: detail)
		}
	}
}

struct V1StoreFailure: Error {
	let step: String
}

extension ULID: Decodable {
	public init(from decoder: Decoder) throws {
		let raw = try decoder.singleValueContainer().decode(String.self)
		guard let parsed = ULID(rawValue: raw) else {
			throw DecodingError.dataCorrupted(
				.init(codingPath: decoder.codingPath, debugDescription: "ulid"))
		}
		self = parsed
	}
}
