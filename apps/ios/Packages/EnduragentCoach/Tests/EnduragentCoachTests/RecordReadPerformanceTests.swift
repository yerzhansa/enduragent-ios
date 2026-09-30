import Foundation
import Testing

@testable import EnduragentCoach

extension SwiftDataSuites {
	@Suite struct RecordReadPerformanceTests {
		@Test func settledReadFitsAttemptBudget() async throws {
			let fixture = try await RecordReadBenchmark(settled: true)
			let conversation = try await fixture.ledger.conversation(.main)
			var samples = PerformanceSamples()
			for _ in 0..<PerformanceSamples.batchCount {
				var before = (fixture.log.reads.count, fixture.log.fetchedRecordCount)
				try await samples.measure(count: 1) {
					try await fixture.ledger.flushJobs(in: conversation)
				} validate: { read in
					#expect(fixture.log.reads.count - before.0 == 1)
					#expect(fixture.log.fetchedRecordCount - before.1 == 400)
					#expect(read.count == fixture.jobs.count)
					#expect(Set(read.map(\.id)) == Set(fixture.jobs))
					#expect(read.allSatisfy { $0.settled })
					before = (fixture.log.reads.count, fixture.log.fetchedRecordCount)
				}
			}
			try samples.check(budget: .milliseconds(50), name: "settled-read")
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
