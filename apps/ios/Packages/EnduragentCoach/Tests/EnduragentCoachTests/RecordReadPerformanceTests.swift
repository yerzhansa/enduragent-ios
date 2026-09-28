import Foundation
import Synchronization
import Testing

@testable import EnduragentCoach

extension SwiftDataSuites {
	@Suite struct RecordReadPerformanceTests {
		@Test func settledReadFitsAttemptBudget() async throws {
			let fixture = try await RecordReadBenchmark(settled: true)
			let conversation = try await fixture.ledger.conversation(.main)
			var samples = PerformanceSamples()
			for _ in 0..<PerformanceSamples.batchCount {
				let formatters = Mutex(0)
				try await samples.measure(count: 1) {
					let before = (fixture.log.reads.count, fixture.log.fetchedRecordCount)
					let read = try await CivilDate.$didCreateFormatter.withValue({
						formatters.withLock { $0 += 1 }
					}) {
						try await fixture.ledger.flushJobs(in: conversation)
					}
					return (
						read, fixture.log.reads.count - before.0,
						fixture.log.fetchedRecordCount - before.1
					)
				} validate: { read, fetches, records in
					#expect(formatters.withLock { $0 } == 0)
					#expect(fetches == 1)
					#expect(records == 400)
					#expect(read.count == fixture.jobs.count)
					#expect(Set(read.map(\.id)) == Set(fixture.jobs))
					#expect(read.allSatisfy { $0.settled })
				}
			}
			let elapsed = try samples.minimum()
			Attachment.record(
				"settled-read minimum_ms=\(elapsed / .milliseconds(1)) reference_budget_ms=50"
					+ " samples=\(samples.batches)", named: "settled-read-cost.txt")
		}

		@Test func measureUnsettledRead() async throws {
			let fixture = try await RecordReadBenchmark(settled: false)
			let conversation = try await fixture.ledger.conversation(.main)
			let started = ContinuousClock.now
			let read = try await fixture.ledger.flushJobs(in: conversation)
			let elapsed = ContinuousClock.now - started
			RecordReadBenchmark.record(elapsed, name: "unsettled-read")
			#expect(read.count == fixture.jobs.count)
			#expect(Set(read.map(\.id)) == Set(fixture.jobs))
			#expect(read.allSatisfy { $0.settled })
		}
	}
}
