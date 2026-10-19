import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

@Suite struct CanceledReviewSnapshotTests {
	let turns = ReviewTurns()

	@Test func aReviewReadThatEndsAfterTheCancelLeavesTheCanceledNoteAndNoCard() async throws {
		let notes = RecordQuery(
			scope: .synced(
				[.reviewOutcome],
				includeLegacy: [.reviewApplied, .reviewWrite, .reviewCancelledUnknown]),
			chatId: .main)
		let observer = HeldReadLog(inner: turns.store, holding: .fetch(notes), .beforeReading)
		let straggler = HeldReadLog(
			inner: observer,
			holding: .fetch(RecordQuery(scope: ConversationFold.syncedScope, chatId: .main)),
			.beforeReading, armed: false)
		let outcome = HeldAppendLog(inner: straggler, holding: "reviewOutcome", occurrence: 1)
		defer {
			outcome.release()
			straggler.release()
			observer.release()
		}
		let coach = await turns.coach(over: outcome)
		await coach.lifecycle(.becameActive)
		_ = await coach.observe(.main)
		await coach.desk.moved(.main)
		try await observer.waitUntilReached()

		let review = try await turns.committed(ReviewTurns.fourChanges, on: coach)
		turns.intervals.events.removeAll { $0.id == EventID(rawValue: 202) }
		let approve = try await armedToken(on: coach)
		#expect(await coach.decide(.approve(approve), in: .main) == .blocked(.cannotVerify))
		let blocked = try #require(try await coach.desk.snapshot(chat: .main))
		let cancel = try await armedToken(on: coach)

		async let canceling = coach.decide(.cancel(cancel), in: .main)
		try await outcome.waitUntilReached()
		straggler.arm()
		async let presenting = coach.decide(.presented(blocked.ref), in: .main)
		try await straggler.waitUntilReached()
		outcome.release()
		guard case .canceled = await canceling else {
			Issue.record("the blocked review was not canceled")
			return
		}
		straggler.release()
		_ = await presenting

		let shown = try #require(await coach.currentSnapshot(.main))
		#expect(shown.review == nil)
		let note = try #require(shown.notes[review.origin.turn]?.last)
		#expect(note.closing(in: displayLocale()) == "The remaining changes were canceled.")
	}

	private func armedToken(on coach: Coach) async throws -> ReviewControlToken {
		let shown = try #require(try await coach.desk.snapshot(chat: .main))
		#expect(await coach.decide(.presented(shown.ref), in: .main) == .presentationRecorded)
		guard
			case .armed(_, let token) = try #require(try await coach.desk.snapshot(chat: .main))
				.controls
		else {
			throw UnexpectedReview(detail: "the review never armed its controls")
		}
		return token
	}
}
