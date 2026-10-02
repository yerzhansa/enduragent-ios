import EnduragentCoachFixtures
import Foundation

@testable import EnduragentCoach

struct FlushCostFixture {
	let rowCount = 2_000
	let settledJobCount = 200
	let pendingJobCount = 3
	private let device = DeviceID(rawValue: "phone-a")
	private let root: URL
	private let synced: ModelContainerHandle
	private let newestLocal: ModelContainerHandle
	private let settled: [AthleteRecord]
	private let clock = FixedClock(
		now: "1998-06-13T12:00:00+02:00", timeZone: "Europe/Amsterdam")

	init() async throws {
		root = try TestTemporaryFolders.make()
		try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
		synced = try ModelContainerHandle.withoutCloudKit(
			storeURL: root.appending(path: "synced.store"))

		newestLocal = try ModelContainerHandle.withoutCloudKit(
			storeURL: root.appending(path: "newest.store"))

		let question = String(repeating: "q", count: 200)
		let answer = String(repeating: "a", count: 1_000)

		var messages: [AthleteRecord] = []
		for turnIndex in 0..<(rowCount / 2) {
			let userRow = 2 * turnIndex
			let turn = TurnID(ulid: fixedUlid(10 + userRow))
			messages.append(
				storedRecord(
					device: device, wall: Int64(1_000 + userRow),
					ulid: fixedUlid(10 + userRow),
					body: .synced(
						sampleUser(chatId: .main, text: "\(turnIndex) \(question)", turn: turn))
				))
			messages.append(
				storedRecord(
					device: device, wall: Int64(1_001 + userRow),
					ulid: fixedUlid(11 + userRow),
					body: .synced(
						sampleReply(chatId: .main, turn: turn, text: "\(turnIndex) \(answer)")))
			)
		}

		var settled: [AthleteRecord] = []
		for jobIndex in 0..<settledJobCount {
			let job = FlushJobID(ulid: fixedUlid(5_000 + jobIndex))
			settled.append(
				storedRecord(
					device: device, wall: Int64(10_000 + jobIndex), ulid: job.ulid,
					body: .deviceLocal(
						.flushPending(
							FlushPendingBody(
								chatId: .main,
								messageUlids: Self.rowUlids((10 * jobIndex)..<(10 * jobIndex + 10)),
								process: ProcessID(ulid: fixedUlid(9_000)))))))
			settled.append(
				storedRecord(
					device: device, wall: Int64(20_000 + jobIndex),
					ulid: fixedUlid(6_000 + jobIndex),
					body: .deviceLocal(
						.flushSettled(
							FlushSettledBody(
								chatId: .main, job: job,
								settlement: .saved(sections: 1, events: 0))))))
		}

		self.settled = settled
		let log = SwiftDataRecordLog(deviceId: device, synced: synced, local: newestLocal)
		try await log.append(messages, locality: .synced)
	}

	func ledger(oldest: Bool) async throws -> (Ledger, BatchRecordingLog) {
		let log = SwiftDataRecordLog(
			deviceId: device, synced: synced,
			local: oldest
				? try ModelContainerHandle.withoutCloudKit(
					storeURL: root.appending(path: "oldest.store"))
				: newestLocal)
		var local = settled

		for pendingIndex in 0..<pendingJobCount {
			let listed =
				oldest
				? Self.rowUlids((20 * pendingIndex + 5)..<(20 * pendingIndex + 15))
				: Self.rowUlids((1_970 + 10 * pendingIndex)..<(1_980 + 10 * pendingIndex))
			local.append(
				storedRecord(
					device: device,
					wall: Int64(oldest ? 9_990 + pendingIndex : 30_000 + pendingIndex),
					ulid: fixedUlid(oldest ? 4_990 + pendingIndex : 5_300 + pendingIndex),
					body: .deviceLocal(
						.flushPending(
							FlushPendingBody(
								chatId: .main, messageUlids: listed,
								process: ProcessID(ulid: fixedUlid(9_000)))))))
		}

		try await log.append(local, locality: .deviceLocal)
		let recording = BatchRecordingLog(inner: log)
		let ledger = Ledger(log: recording, clock: clock, diagnostics: DiagnosticsLog(clock: clock))
		_ = try await ledger.read(RecordQuery(scope: .deviceLocal([])))

		return (ledger, recording)
	}

	private static func rowUlids(_ range: Range<Int>) -> [ULID] {
		range.map { fixedUlid(10 + $0) }
	}
}
