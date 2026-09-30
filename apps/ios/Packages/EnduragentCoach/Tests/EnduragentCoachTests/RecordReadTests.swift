import Testing

@testable import EnduragentCoach

extension SwiftDataSuites {
	@Suite struct RecordReadTests {
		@Test(arguments: [false, true])
		func flushReadFetchesOnlyRequiredRows(settled: Bool) async throws {
			let fixture = try await RecordReadFixture(settled: settled)
			let conversation = try await fixture.ledger.conversation(.main)
			let before = (fixture.log.reads.count, fixture.log.fetchedRecordCount)
			let read = try await fixture.ledger.flushJobs(in: conversation)
			#expect(fixture.log.reads.count - before.0 == (settled ? 1 : 2))
			#expect(fixture.log.fetchedRecordCount - before.1 == (settled ? 400 : 5_400))
			#expect(read.count == fixture.jobs.count)
			#expect(Set(read.map(\.id)) == Set(fixture.jobs))
			#expect(read.allSatisfy { $0.settled })
		}
	}
}
