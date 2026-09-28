import Foundation
import Testing

@testable import EnduragentCoach

extension SwiftDataSuites {
	@Suite struct FlushCostPerformanceTests {
		@Test func settledHistoryCostWithPendingJobs() async throws {
			let fixture = try await FlushCostBenchmark()
			for oldest in [false, true] {
				let ledger = try await fixture.ledger(oldest: oldest)
				let conversation = try await ledger.conversation(.main)
				var flush = RelativeCostSamples()
				var transcript = RelativeCostSamples()
				for _ in 0..<3 {
					let readStarted = ContinuousClock.now
					let local = try await ledger.read(
						RecordQuery(
							scope: ConversationFold.flushScope, chatId: .main,
							writtenBy: ledger.deviceId))
					flush.baseline.append(ContinuousClock.now - readStarted)
					#expect(
						local.records.count == 2 * fixture.settledJobCount + fixture.pendingJobCount
					)

					let flushStarted = ContinuousClock.now
					let jobs = try await ledger.flushJobs(in: conversation)
					flush.measured.append(ContinuousClock.now - flushStarted)
					#expect(jobs.count == fixture.settledJobCount + fixture.pendingJobCount)
					#expect(jobs.filter { $0.settled }.count == fixture.settledJobCount)

					let foldStarted = ContinuousClock.now
					let folded = try await ledger.conversation(.main)
					transcript.baseline.append(ContinuousClock.now - foldStarted)
					#expect(folded == conversation)

					let transcriptStarted = ContinuousClock.now
					let loaded = try await ledger.loadTranscript(
						chatId: .main, excluding: TurnID(ulid: fixedUlid(99_000)))
					transcript.measured.append(ContinuousClock.now - transcriptStarted)
					#expect(loaded.pending.count == 10 * fixture.pendingJobCount)
					#expect(loaded.unflushed.isEmpty)
					#expect(loaded.history.messages.count == fixture.rowCount)
					#expect(loaded.flushPending)
				}
				let placement = oldest ? "oldest" : "newest"
				try flush.check(limit: 3, name: "\(placement)-flush-jobs")
				try transcript.check(limit: 2.5, name: "\(placement)-transcript")
			}
		}
	}
}
