import Foundation
import Testing

@testable import EnduragentCoach

extension SwiftDataSuites {
	@Suite struct RecordReadPerformanceTests {
		@Test func settledReadFitsAttemptBudget() async throws {
			let fixture = try await RecordReadBenchmark(settled: true)
			let conversation = try await fixture.ledger.conversation(.main)
			var samples = RelativeCostSamples()
			for _ in 0..<3 {
				let baselineStarted = ContinuousClock.now
				let local = try await fixture.ledger.read(
					RecordQuery(
						scope: ConversationFold.flushScope, chatId: .main,
						writtenBy: fixture.ledger.deviceId))
				samples.baseline.append(ContinuousClock.now - baselineStarted)
				#expect(local.records.count == 2 * fixture.jobs.count)
				let started = ContinuousClock.now
				let read = try await fixture.ledger.flushJobs(in: conversation)
				samples.measured.append(ContinuousClock.now - started)
				#expect(read.count == fixture.jobs.count)
				#expect(Set(read.map(\.id)) == Set(fixture.jobs))
				#expect(read.allSatisfy { $0.settled })
			}
			try samples.check(limit: 3, name: "settled-read")
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
