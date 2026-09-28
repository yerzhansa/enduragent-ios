import Foundation
import Testing

@testable import EnduragentCoach

extension SwiftDataSuites {
	@Suite struct RecordReadPerformanceTests {
		@Test func settledReadFitsAttemptBudget() async throws {
			let fixture = try await RecordReadBenchmark(settled: true)
			let conversation = try await fixture.ledger.conversation(.main)
			var samples: [Duration] = []
			for _ in 0..<3 {
				let started = ContinuousClock.now
				let read = try await fixture.ledger.flushJobs(in: conversation)
				samples.append(ContinuousClock.now - started)
				#expect(read.count == fixture.jobs.count)
				#expect(Set(read.map(\.id)) == Set(fixture.jobs))
				#expect(read.allSatisfy { $0.settled })
			}
			let median = try #require(samples.sorted().dropFirst().first)
			RecordReadBenchmark.record(median, name: "settled-read-median")
			Attachment.record(
				samples.map { String(format: "%.3f", $0 / .milliseconds(1)) }.joined(
					separator: " "),
				named: "settled-read-samples-ms.txt")
			#expect(median < .milliseconds(50), "400 local records: \(samples)")
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
