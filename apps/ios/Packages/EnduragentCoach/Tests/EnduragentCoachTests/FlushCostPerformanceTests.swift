import Foundation
import Testing

@testable import EnduragentCoach

extension SwiftDataSuites {
	@Suite struct FlushCostPerformanceTests {
		private static let flushJobsBudget = Duration.milliseconds(50)
		private static let transcriptBudget = Duration.milliseconds(300)

		@Test(arguments: ["newest", "oldest"])
		func settledHistoryCostWithPendingJobs(pendingPlacement: String) async throws {
			let device = DeviceID(rawValue: "phone-a")
			let root = FileManager.default.temporaryDirectory.appending(
				path: "enduragent-flush-cost-\(UUID().uuidString)", directoryHint: .isDirectory)
			try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
			let log = SwiftDataRecordLog(
				deviceId: device,
				synced: try ModelContainerHandle.withoutCloudKit(
					storeURL: root.appending(path: "synced.store")),
				local: try ModelContainerHandle.withoutCloudKit(
					storeURL: root.appending(path: "local.store")))

			let rowCount = 2_000
			let settledJobCount = 200
			let pendingJobCount = 3
			let question = String(repeating: "q", count: 200)
			let answer = String(repeating: "a", count: 1_000)
			func rowUlids(_ range: Range<Int>) -> [ULID] {
				range.map { fixedUlid(10 + $0) }
			}

			var synced: [AthleteRecord] = []
			for turnIndex in 0..<(rowCount / 2) {
				let userRow = 2 * turnIndex
				let turn = TurnID(ulid: fixedUlid(10 + userRow))
				synced.append(
					storedRecord(
						device: device, wall: Int64(1_000 + userRow),
						ulid: fixedUlid(10 + userRow),
						body: .synced(
							sampleUser(chatId: .main, text: "\(turnIndex) \(question)", turn: turn))
					))
				synced.append(
					storedRecord(
						device: device, wall: Int64(1_001 + userRow),
						ulid: fixedUlid(11 + userRow),
						body: .synced(
							sampleReply(chatId: .main, turn: turn, text: "\(turnIndex) \(answer)")))
				)
			}

			var local: [AthleteRecord] = []
			for jobIndex in 0..<settledJobCount {
				let job = FlushJobID(ulid: fixedUlid(5_000 + jobIndex))
				local.append(
					storedRecord(
						device: device, wall: Int64(10_000 + jobIndex), ulid: job.ulid,
						body: .deviceLocal(
							.flushPending(
								FlushPendingBody(
									chatId: .main, trigger: .softThreshold,
									messageUlids: rowUlids((10 * jobIndex)..<(10 * jobIndex + 10)),
									process: ProcessID(ulid: fixedUlid(9_000)))))))
				local.append(
					storedRecord(
						device: device, wall: Int64(20_000 + jobIndex),
						ulid: fixedUlid(6_000 + jobIndex),
						body: .deviceLocal(
							.flushSettled(
								FlushSettledBody(
									chatId: .main, job: job,
									settlement: .saved(sections: 1, events: 0))))))
			}

			for pendingIndex in 0..<pendingJobCount {
				let oldest = pendingPlacement == "oldest"
				let listed =
					oldest
					? rowUlids((20 * pendingIndex + 5)..<(20 * pendingIndex + 15))
					: rowUlids((1_970 + 10 * pendingIndex)..<(1_980 + 10 * pendingIndex))
				local.append(
					storedRecord(
						device: device,
						wall: Int64(oldest ? 9_990 + pendingIndex : 30_000 + pendingIndex),
						ulid: fixedUlid(oldest ? 4_990 + pendingIndex : 5_300 + pendingIndex),
						body: .deviceLocal(
							.flushPending(
								FlushPendingBody(
									chatId: .main, trigger: .trim, messageUlids: listed,
									process: ProcessID(ulid: fixedUlid(9_000)))))))
			}

			try await log.append(synced, locality: .synced)
			try await log.append(local, locality: .deviceLocal)
			let clock = FixedClock(
				now: "1998-06-13T12:00:00+02:00", timeZone: "Europe/Amsterdam")
			let ledger = Ledger(log: log, clock: clock, diagnostics: DiagnosticsLog(clock: clock))
			_ = try await ledger.read(RecordQuery(scope: .deviceLocal([])))

			let conversation = try await ledger.conversation(.main)
			var flushJobsSamples: [Duration] = []
			var transcriptSamples: [Duration] = []
			for _ in 0..<3 {
				let flushJobsStarted = ContinuousClock.now
				let jobs = try await ledger.flushJobs(in: conversation)
				flushJobsSamples.append(ContinuousClock.now - flushJobsStarted)
				#expect(jobs.count == settledJobCount + pendingJobCount)
				#expect(jobs.filter { $0.settled }.count == settledJobCount)

				let transcriptStarted = ContinuousClock.now
				let transcript = try await ledger.loadTranscript(
					chatId: .main, excluding: TurnID(ulid: fixedUlid(99_000)))
				transcriptSamples.append(ContinuousClock.now - transcriptStarted)
				#expect(transcript.pending.count == 10 * pendingJobCount)
				#expect(transcript.unflushed.isEmpty)
				#expect(transcript.history.messages.count == rowCount)
				#expect(transcript.flushPending)
			}

			let flushJobsMedian = try #require(flushJobsSamples.sorted().dropFirst().first)
			let transcriptMedian = try #require(transcriptSamples.sorted().dropFirst().first)
			record(
				flushJobsSamples, median: flushJobsMedian,
				name: "\(pendingPlacement)-flush-jobs")
			record(
				transcriptSamples, median: transcriptMedian,
				name: "\(pendingPlacement)-transcript")
			try appendResult(
				placement: pendingPlacement, flushJobs: flushJobsSamples,
				flushJobsMedian: flushJobsMedian, transcript: transcriptSamples,
				transcriptMedian: transcriptMedian)

			#expect(
				flushJobsMedian < Self.flushJobsBudget,
				"2,000 rows, 200 settled jobs, \(pendingPlacement) pending: \(flushJobsSamples)")
			#expect(
				transcriptMedian < Self.transcriptBudget,
				"2,000-row transcript samples: \(transcriptSamples)")
		}

		private func record(_ samples: [Duration], median: Duration, name: String) {
			Attachment.record(
				String(format: "%.3f", median / .milliseconds(1)), named: "\(name)-median-ms.txt")
			Attachment.record(
				samples.map { String(format: "%.3f", $0 / .milliseconds(1)) }.joined(
					separator: " "),
				named: "\(name)-samples-ms.txt")
		}

		private func appendResult(
			placement: String, flushJobs: [Duration], flushJobsMedian: Duration,
			transcript: [Duration], transcriptMedian: Duration
		) throws {
			guard let path = ProcessInfo.processInfo.environment["FLUSH_COST_OUT"] else { return }
			let milliseconds = { (duration: Duration) in
				String(format: "%.2f", duration / .milliseconds(1))
			}
			let line =
				"placement=\(placement) flushJobs_median_ms=\(milliseconds(flushJobsMedian))"
				+ " transcript_median_ms=\(milliseconds(transcriptMedian))"
				+ " flushJobs_samples=\(flushJobs.map(milliseconds).joined(separator: ","))"
				+ " transcript_samples=\(transcript.map(milliseconds).joined(separator: ","))\n"
			let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
			try handle.seekToEnd()
			try handle.write(contentsOf: Data(line.utf8))
			try handle.close()
		}
	}
}
