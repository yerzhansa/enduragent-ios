import Foundation
import Testing

@testable import EnduragentCoach

extension WorkoutReviewTransitionTests {
	@Test func aLostAnswerReadsFirstAndASettleThatFindsTheChangeStillStops() throws {
		let sending = try ReviewStages()[.sending]
		let attempt = try #require(sendAttempt(of: sending))
		let losses: [LostAnswer] = [
			.transport, .unreadableBody, .canceled, .serverStatus(500), .answerNamesOtherEvent,
		]
		for loss in losses {
			#expect(try sending.answered(.lost(loss), at: reviewClock) == .readFirst(attempt))
		}
		let settled = try #require(try sending.settled(.seen(EventID(rawValue: 301))))
		#expect(settled.stage == .waiting(.tryAgain(.settled)))
		#expect(
			settled.work.finished
				== [
					FinishedChange(
						change: attempt.change, result: .seenOnCalendar(EventID(rawValue: 301)))
				])
		#expect(settled.work.remaining == sending.work.remaining)
	}

	@Test func aRefusedAnswerPutsTheChangeBackAtTheHeadOfTheRemainingWork() throws {
		let sending = try ReviewStages()[.sending]
		let attempt = try #require(sendAttempt(of: sending))
		for status in [400, 401, 403, 404, 429] {
			let refusal = try #require(RefusalStatus(rawValue: status))
			let refused = try next(try sending.answered(.refused(refusal), at: reviewClock))
			#expect(refused.stage == .waiting(.tryAgain(.refused(attempt.change.id, refusal))))
			#expect(refused.work.remaining == [attempt.change] + sending.work.remaining)
			#expect(refused.work.finished == sending.work.finished)
		}
	}

	@Test func seenAddsFinishWithoutAReceiptAndTheFirstUnseenChangeIsSent() throws {
		let stages = try ReviewStages()
		let checking = try stages[.checking]
		let partly = try checking.sending(
			at: reviewClock,
			seen: [
				reviewChange(401): EventID(rawValue: 301), reviewChange(402): EventID(rawValue: 9),
			])
		#expect(partly.work.finished.map(\.result) == [.seenOnCalendar(EventID(rawValue: 301))])
		#expect(try #require(sendAttempt(of: partly)).change.id == reviewChange(402))
		#expect(partly.work.remaining.map(\.id) == [reviewChange(403)])
		let afterWork = try stages[.checkingAfterWork]
		let whole = try afterWork.sending(
			at: reviewClock, seen: [reviewChange(405): EventID(rawValue: 305)])
		#expect(whole.stage == .completed)
		#expect(whole.work.remaining.isEmpty)
		#expect(
			whole.work.finished.dropFirst(afterWork.work.finished.count).map(\.result) == [
				.seenOnCalendar(EventID(rawValue: 305))
			])
	}

	@Test func aSavedAnswerKeepsItsReceiptAndStartsTheNextSendAttemptInTheSameValue() throws {
		let stages = try ReviewStages()
		let sending = try stages[.sending]
		let later = reviewClock.addingTimeInterval(30)
		let saved = try next(try sending.answered(.saved(stages.receipt), at: later))
		#expect(saved.work.finished.map(\.result) == [.saved(stages.receipt)])
		let attempt = try #require(sendAttempt(of: saved))
		#expect(attempt.change.id == reviewChange(402))
		#expect(attempt.sentAt == later)
		#expect(saved.work.remaining.map(\.id) == [reviewChange(403)])
	}

	@Test func aDeleteAnsweredGoneFinishesAsNoLongerOnTheCalendar() throws {
		let stages = try ReviewStages()
		let editing = try stages[.checking].sending(
			at: reviewClock, seen: [reviewChange(401): EventID(rawValue: 301)])
		let deleting = try next(try editing.answered(.saved(stages.receipt), at: reviewClock))
		#expect(try #require(sendAttempt(of: deleting)).change.id == reviewChange(403))
		let gone = try next(try deleting.answered(.gone, at: reviewClock))
		#expect(gone.stage == .completed)
		#expect(gone.work.finished.last?.result == .noLongerOnCalendar)
	}

	@Test func aRefreshedReviewRaisesTheRevisionAndReviewsTheCurrentTarget() throws {
		let checking = try ReviewStages()[.checking]
		let kept = [KeptWorkout(name: "Recovery spin", date: "1998-06-22", durationMinutes: 40)]
		let refreshed = try checking.refreshed(
			[Self.edit: Self.current], kept: kept, differences: Self.differences)
		#expect(refreshed.revision == checking.revision.next)
		#expect(refreshed.kept == kept)
		let edited = try #require(refreshed.work.remaining.first { $0.id == Self.edit })
		guard case .edit(let edit) = edited.action else {
			throw UnexpectedReview(detail: "the refreshed change is not an edit")
		}
		#expect(edit.target == .reviewed(EventID(rawValue: 101), Self.current))
	}

	@Test func cancelKeepsFinishedWorkAndTheUnconfirmedChangeAsANote() throws {
		let stages = try ReviewStages()
		let unconfirmed = try stages[.unconfirmedUpgraded]
		let canceled = try stages[.canceled]
		let note = try #require(sendAttempt(of: unconfirmed))
		#expect(canceled.work.finished == unconfirmed.work.finished)
		#expect(
			canceled.stage
				== .canceled(Cancellation(givenUp: unconfirmed.work.remaining, unconfirmed: note)))
	}

	private func sendAttempt(of review: WorkoutReview) -> SendAttempt? {
		switch review.stage {
		case .running(let run): run.sending
		case .waiting(.unconfirmed(let attempt)): attempt
		case .waiting, .completed, .canceled: nil
		}
	}
}
