import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

extension SwiftDataSuites {
	@Suite struct UpgradeOutcomeStoreTests {
		@Test func build6833d90fOpenReviewShowsOneClosedAtUpgradeNoteInTheConversation()
			async throws
		{
			let seed = try await M2Seed(
				try UpgradeStore("open-review", folder: M2Seed.folder, device: M2Seed.device).log)

			await (try seed.desk()).recover()
			await (try seed.desk()).recover()

			let notes = try await seed.ledger().conversation(.main).current.notes
			#expect(
				ReviewOutcomeNotesTests.sentences(notes) == [
					"This review was prepared before the app was updated. Ask the coach again."
				])
			#expect(notes.map(\.after) == [seed.turn])
		}

		@Test(arguments: UpgradeStore.UnreadableRow.allCases)
		func build6833d90fOpenReviewClosesBesideASyncedOutcomeThisBuildCannotRead(
			_ unreadable: UpgradeStore.UnreadableRow
		) async throws {
			let store = try UpgradeStore(
				"open-review", folder: M2Seed.folder, device: M2Seed.device)
			let seed = try await M2Seed(store.log)
			let later = seed.clock.now.addingTimeInterval(60)
			let laterBuild = DeviceID(rawValue: "later-build")
			try store.sync(
				storedRecord(
					device: laterBuild, wall: Int64(later.timeIntervalSince1970 * 1000),
					ulid: ULID.generate(at: later), account: seed.account,
					body: .synced(
						.reviewOutcome(
							ReviewOutcomeBody(
								chatId: .main,
								review: WorkoutReviewID(ulid: ULID.generate(at: later)),
								revision: ReviewRevision(rawValue: 1), after: nil,
								ending: .completed,
								lines: [])))),
				as: unreadable)

			await (try seed.desk()).recover()

			#expect(
				try await seed.outcomes() == [
					ReviewOutcomeBody(
						chatId: .main, review: seed.review, revision: ReviewRevision(rawValue: 1),
						after: seed.turn, ending: .closedAtUpgrade, lines: [])
				])
			#expect(
				try await store.log.fetch(RecordQuery(scope: .synced([.reviewOutcome]))).skipped
					.count
					== 1)
		}
	}
}
