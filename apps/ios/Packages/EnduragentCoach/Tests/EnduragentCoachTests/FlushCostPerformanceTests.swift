import EnduragentCoachFixtures
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
				let batchCount = 9
				var localRead = PerformanceSamples(expectedBatchCount: batchCount)
				var flush = PerformanceSamples(expectedBatchCount: batchCount)
				var fold = PerformanceSamples(expectedBatchCount: batchCount)
				var transcript = PerformanceSamples(expectedBatchCount: batchCount)
				for _ in 0..<batchCount {
					try await localRead.measure(count: 1) {
						try await ledger.read(
							RecordQuery(
								scope: ConversationFold.flushScope, chatId: .main,
								writtenBy: ledger.deviceId))
					} validate: { local in
						#expect(
							local.records.count == 2 * fixture.settledJobCount
								+ fixture.pendingJobCount
						)
					}
					try await flush.measure(count: 1) {
						try await ledger.flushJobs(in: conversation)
					} validate: { jobs in
						#expect(jobs.count == fixture.settledJobCount + fixture.pendingJobCount)
						#expect(jobs.filter { $0.settled }.count == fixture.settledJobCount)
					}
					try await fold.measure(count: 1) {
						try await ledger.conversation(.main)
					} validate: { folded in
						#expect(folded == conversation)
					}
					try await transcript.measure(count: 1) {
						try await ledger.loadTranscript(
							chatId: .main, excluding: TurnID(ulid: fixedUlid(99_000)))
					} validate: { loaded in
						#expect(loaded.pending.count == 10 * fixture.pendingJobCount)
						#expect(loaded.unflushed.isEmpty)
						#expect(loaded.history.messages.count == fixture.rowCount)
						#expect(loaded.flushPending)
					}
				}
				let placement = oldest ? "oldest" : "newest"
				try flush.check(relativeTo: localRead, limit: 3, name: "\(placement)-flush-jobs")
				try transcript.check(relativeTo: fold, limit: 2.5, name: "\(placement)-transcript")
			}
		}
	}
}
