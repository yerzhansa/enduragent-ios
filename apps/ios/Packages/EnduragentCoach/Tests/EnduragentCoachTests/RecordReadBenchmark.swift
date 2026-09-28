import Foundation
import Testing

@testable import EnduragentCoach

struct RecordReadBenchmark {
	let ledger: Ledger
	let log: BatchRecordingLog
	let jobs: [FlushJobID]

	init(settled: Bool) async throws {
		let root = FileManager.default.temporaryDirectory.appending(
			path: "enduragent-read-benchmark-\(UUID().uuidString)", directoryHint: .isDirectory)
		let local = try ModelContainerHandle.withoutCloudKit(
			storeURL: root.appending(path: "local.store"))
		let synced = try ModelContainerHandle.withoutCloudKit(
			storeURL: root.appending(path: "synced.store"))
		let device = DeviceID(rawValue: "phone-a")
		let log = BatchRecordingLog(
			inner: SwiftDataRecordLog(deviceId: device, synced: synced, local: local))
		self.log = log
		let jobs = (1...200).map { FlushJobID(ulid: fixedUlid($0)) }
		self.jobs = jobs
		let pending = jobs.map { job in
			storedRecord(
				device: device, wall: 1, ulid: job.ulid,
				body: .deviceLocal(
					.flushPending(
						FlushPendingBody(
							chatId: .main, trigger: .softThreshold, messageUlids: [job.ulid]))))
		}
		let settlements = jobs.enumerated().map { index, job in
			storedRecord(
				device: device, wall: 2, ulid: fixedUlid(201 + index),
				body: .deviceLocal(
					.flushSettled(
						FlushSettledBody(
							chatId: .main,
							job: settled ? job : FlushJobID(ulid: fixedUlid(10_000 + index)),
							settlement: .nothingToSave))))
		}
		let provenance = (0..<5_000).map { index in
			let key =
				index < jobs.count
				? MemoryFlushPolicy.consumedFlushKeyPrefix + jobs[index].ulid.rawValue
				: "activity:\(index)"
			return storedRecord(
				device: device, wall: 3, ulid: fixedUlid(401 + index),
				body: .synced(
					.provenance(
						ProvenanceBody(
							key: key, garmin: false, nonGarmin: false, unknown: false,
							contentSha256: "consumed"))))
		}
		try await log.append(pending + settlements, locality: .deviceLocal)
		try await log.append(provenance, locality: .synced)
		let clock = FixedClock(now: "1998-06-13T12:00:00+02:00", timeZone: "Europe/Amsterdam")
		ledger = Ledger(log: log, clock: clock, diagnostics: DiagnosticsLog(clock: clock))
		_ = try await ledger.read(RecordQuery(scope: .deviceLocal([])))
	}

	static func record(_ elapsed: Duration, name: String) {
		Attachment.record(
			String(format: "%.3f", elapsed / .milliseconds(1)), named: "\(name)-ms.txt")
	}
}
