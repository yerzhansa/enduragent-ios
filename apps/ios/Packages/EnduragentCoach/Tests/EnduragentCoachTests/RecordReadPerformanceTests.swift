import Foundation
import Testing

@testable import EnduragentCoach

extension SwiftDataSuites {
	@Suite struct RecordReadPerformanceTests {
		@Test func settledReadFitsAttemptBudget() async throws {
			let fixture = try await RecordReadBenchmark(settled: true)
			let started = ContinuousClock.now
			let read = try await fixture.ledger.flushJobs(in: .main)
			let elapsed = ContinuousClock.now - started
			RecordReadBenchmark.record(elapsed, name: "settled-read")
			#expect(read.count == fixture.jobs.count)
			#expect(Set(read.map(\.id)) == Set(fixture.jobs))
			#expect(read.allSatisfy { $0.settled })
			#expect(elapsed < .milliseconds(50), "400 local records: \(elapsed)")
		}

		@Test func measureUnsettledRead() async throws {
			let fixture = try await RecordReadBenchmark(settled: false)
			let started = ContinuousClock.now
			let read = try await fixture.ledger.flushJobs(in: .main)
			let elapsed = ContinuousClock.now - started
			RecordReadBenchmark.record(elapsed, name: "unsettled-read")
			#expect(read.count == fixture.jobs.count)
			#expect(Set(read.map(\.id)) == Set(fixture.jobs))
			#expect(read.allSatisfy { $0.settled })
		}

		@Test func profileStoredRecordRead() async throws {
			let fixture = try await RecordReadBenchmark(settled: false)
			let localStarted = ContinuousClock.now
			let local = try await fixture.ledger.read(
				RecordQuery(scope: ConversationFold.flushScope))
			RecordReadBenchmark.record(ContinuousClock.now - localStarted, name: "local-read")
			#expect(local.records.count == 400)
			let provenanceStarted = ContinuousClock.now
			let provenance = try await fixture.ledger.read(
				RecordQuery(scope: ConversationFold.consumedMarkerScope))
			RecordReadBenchmark.record(
				ContinuousClock.now - provenanceStarted, name: "provenance-read")
			#expect(provenance.records.count == 5_000)
			try fixture.profile(fixture.local, name: "local", expected: 400)
			try fixture.profile(fixture.synced, name: "provenance", expected: 5_000)
		}
	}
}
