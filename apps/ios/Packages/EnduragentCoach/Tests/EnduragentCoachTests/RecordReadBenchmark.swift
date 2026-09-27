import Foundation
import SwiftData
import Testing

@testable import EnduragentCoach

struct RecordReadBenchmark {
	let local: ModelContainerHandle
	let synced: ModelContainerHandle
	let log: SwiftDataRecordLog
	let ledger: Ledger
	let jobs: [FlushJobID]

	init(settled: Bool) async throws {
		let root = FileManager.default.temporaryDirectory.appending(
			path: "enduragent-read-benchmark-\(UUID().uuidString)", directoryHint: .isDirectory)
		local = try .withoutCloudKit(storeURL: root.appending(path: "local.store"))
		synced = try .withoutCloudKit(storeURL: root.appending(path: "synced.store"))
		let device = DeviceID(rawValue: "phone-a")
		log = SwiftDataRecordLog(deviceId: device, synced: synced, local: local)
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

	func profile(_ handle: ModelContainerHandle, name: String, expected: Int) throws {
		let started = ContinuousClock.now
		let context = ModelContext(handle.container)
		let rows = try context.fetch(FetchDescriptor<StoredAthleteRecord>())
		Self.record(ContinuousClock.now - started, name: "\(name)-fetch")
		#expect(rows.count == expected)
		let decodeStarted = ContinuousClock.now
		let decoded = try rows.map { try $0.decode().get() }
		Self.record(ContinuousClock.now - decodeStarted, name: "\(name)-decode")
		let keys = rows.map(\.civilDate)
		let dateStarted = ContinuousClock.now
		let validDates = keys.filter { CivilDate(rawValue: $0) != nil }
		Self.record(ContinuousClock.now - dateStarted, name: "\(name)-civil-date")
		#expect(validDates.count == expected)
		let sortStarted = ContinuousClock.now
		let sorted = decoded.sorted { $0.hlc < $1.hlc }
		Self.record(ContinuousClock.now - sortStarted, name: "\(name)-sort")
		#expect(sorted.count == expected)
	}

	static func record(_ elapsed: Duration, name: String) {
		Attachment.record(
			String(format: "%.3f", elapsed / .milliseconds(1)), named: "\(name)-ms.txt")
	}
}
