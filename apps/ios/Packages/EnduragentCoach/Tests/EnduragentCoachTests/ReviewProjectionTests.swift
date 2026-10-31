import Foundation
import Testing

@testable import EnduragentCoach

struct ReviewProjectionTests {
	let attribution = AthleteAttribution(
		accounts: [], using: InformationOwnership(records: []),
		device: DeviceID(rawValue: "projection-phone"))

	@Test func cardsFollowPositionAcrossFinishedWorkTheUnconfirmedChangeAndTheRemainingWork()
		throws
	{
		let review = try reviewFixture("workout-review-unconfirmed")
		let content = try #require(snapshot(of: review).content)

		#expect(content.cards.map(\.index) == [0, 1, 2, 3, 4])
		#expect(
			content.cards.map(\.progress) == [
				.saved(EventID(rawValue: 201)), .seenOnCalendar, .noLongerOnCalendar,
				.mayHaveBeenSaved, .remaining,
			])
		#expect(
			content.receipts == [
				ReviewReceipt(index: 0, progress: .saved(EventID(rawValue: 201))),
				ReviewReceipt(index: 1, progress: .seenOnCalendar),
				ReviewReceipt(index: 2, progress: .noLongerOnCalendar),
				ReviewReceipt(index: 3, progress: .mayHaveBeenSaved),
			])
		#expect(ReviewProjection.receipts(of: review) == content.receipts)
	}

	@Test func cardsAreOrderedByPositionNotByWhereEachChangeIsHeld() throws {
		let stored = String(decoding: try fixtureData("workout-review-approval"), as: UTF8.self)
		let swapped =
			stored
			.replacingOccurrences(of: "\"position\": 0", with: "\"position\": first")
			.replacingOccurrences(of: "\"position\": 2", with: "\"position\": 0")
			.replacingOccurrences(of: "\"position\": first", with: "\"position\": 2")
		#expect(swapped != stored)
		let approval = try WorkoutReviewPayload.decode(Data(swapped.utf8))
		let sending = try approval.claimed(Claim(id: claimID(1), action: .approve))
			.sending(at: reviewClock, seen: [:])
		let cards = try #require(snapshot(of: sending).content).cards

		#expect(cards.map(\.index) == [0, 1, 2])
		#expect(cards.map(\.action) == [.delete, .edit(previousName: "Endurance"), .add])
		#expect(cards.map(\.progress) == [.remaining, .remaining, .sending])
	}

	@Test func aCanceledReviewKeepsItsUnconfirmedChangeInPositionOrder() throws {
		let review = try reviewFixture("workout-review-canceled")
		let content = try #require(snapshot(of: review).content)

		#expect(content.cards.map(\.index) == [0, 1])
		#expect(content.cards.map(\.progress) == [.mayHaveBeenSaved, .remaining])
	}

	@Test func aRefusedChangeShowsRefusedAndASentChangeShowsSending() throws {
		let refused = try #require(
			snapshot(of: try reviewFixture("workout-review-try-again")).content)
		let sending = try #require(
			snapshot(of: try reviewFixture("workout-review-sending")).content)
		let notSaved = try #require(
			snapshot(of: try reviewFixture("workout-review-not-saved")).content)

		#expect(refused.cards.map(\.progress) == [.refused])
		#expect(refused.receipts == [ReviewReceipt(index: 0, progress: .refused)])
		#expect(sending.cards.map(\.progress) == [.sending])
		#expect(sending.receipts == [])
		#expect(notSaved.cards.last?.progress == .remaining)
	}

	@Test(arguments: ["workout-review-completed", "workout-review-canceled"])
	func aFinishedReviewIsShownReadOnlyWithNoControl(_ fixture: String) throws {
		let review = try reviewFixture(fixture)
		let delivery = Delivery.fresh(for: review, at: reviewULID(601)).acknowledge()
		let shown = ReviewProjection.snapshot(
			of: review, delivery: delivery, placement: .preparedEarlier, attribution: attribution)

		#expect(shown.controls == ReviewControls.none)
		#expect(!shown.cards.isEmpty)
	}

	@Test func aWaitingReviewShowsTheDeliveredControlsWhereItIsPlaced() throws {
		let review = try reviewFixture("workout-review-approval")
		let turn = TurnID(ulid: reviewULID(200))
		let shown = Delivery.fresh(for: review, at: reviewULID(601))
		let armed = shown.acknowledge()

		let before = ReviewProjection.snapshot(
			of: review, delivery: shown, placement: .afterTurn(turn), attribution: attribution)
		let after = ReviewProjection.snapshot(
			of: review, delivery: armed, placement: .afterTurn(turn), attribution: attribution)

		#expect(before.controls == ReviewControls.none)
		guard case .armed(.approveOrCancel, let token) = after.controls else {
			Issue.record("expected Approve and Cancel, got \(after.controls)")
			return
		}
		#expect(armed.admits(token))
		#expect(after.ref == armed.ref)
		#expect(after.placement == .afterTurn(turn))
		#expect(after.kept == review.kept)
		#expect(
			after.totals
				== ReviewTotals(additions: 1, edits: 1, deletions: 1, durationMinutes: 125))
	}

	private func snapshot(of review: WorkoutReview) -> ReviewSnapshot {
		ReviewProjection.snapshot(
			of: review, delivery: Delivery.fresh(for: review, at: reviewULID(601)),
			placement: .preparedEarlier, attribution: attribution)
	}
}
