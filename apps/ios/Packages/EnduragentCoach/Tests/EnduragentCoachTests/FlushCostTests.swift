import Synchronization
import Testing

@testable import EnduragentCoach

extension SwiftDataSuites {
	@Suite struct FlushCostTests {
		@Test(arguments: [false, true])
		func settledHistoryReadsAndResolvesRowsOncePerPass(oldest: Bool) async throws {
			let fixture = try await FlushCostFixture()
			let (ledger, log) = try await fixture.ledger(oldest: oldest)
			let conversation = try await ledger.conversation(.main)
			let before = (log.reads.count, log.fetchedRecordCount)
			let resolved = Mutex(0)
			let jobs = try await ConversationRows.$didResolveRow.withValue({
				resolved.withLock { $0 += 1 }
			}) {
				try await ledger.flushJobs(in: conversation)
			}
			#expect(jobs.count == fixture.settledJobCount + fixture.pendingJobCount)
			#expect(jobs.filter { $0.phase != .pending }.count == fixture.settledJobCount)
			#expect(log.reads.count - before.0 == 1)
			#expect(
				log.fetchedRecordCount - before.1 == 2 * fixture.settledJobCount
					+ fixture.pendingJobCount)
			#expect(resolved.withLock { $0 } == fixture.rowCount)

			let transcriptBefore = (log.reads.count, log.fetchedRecordCount)
			resolved.withLock { $0 = 0 }
			let loaded = ConversationRows.$didResolveRow.withValue({
				resolved.withLock { $0 += 1 }
			}) {
				Transcript(
					conversation: conversation, jobs: jobs,
					excluding: TurnID(ulid: fixedUlid(99_000)), for: .unconnected,
					device: ledger.deviceId, using: conversation.ownership)
			}
			#expect(loaded.pending.count == 10 * fixture.pendingJobCount)
			#expect(loaded.unflushed.isEmpty)
			#expect(loaded.history.messages.count == fixture.rowCount)
			#expect(loaded.flushPending)
			#expect(log.reads.count - transcriptBefore.0 == 0)
			#expect(
				log.fetchedRecordCount - transcriptBefore.1 == 0)
			#expect(resolved.withLock { $0 } == fixture.rowCount)
		}
	}
}
