import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

@Suite struct CanceledReviewSnapshotTests {
	static let notes = RecordQuery(
		scope: .synced(
			[.reviewOutcome],
			includeLegacy: [.reviewApplied, .reviewWrite, .reviewCancelledUnknown]),
		chatId: .main)
	static let outcomes = RecordQuery(scope: .synced([.reviewOutcome]), chatId: .main)
	static let conversation = RecordQuery(scope: ConversationFold.syncedScope, chatId: .main)

	let turns = ReviewTurns()

	@Test func aReviewReadThatEndsAfterTheCancelLeavesTheCanceledNoteAndNoCard() async throws {
		let observer = HeldReadLog(inner: turns.store, holding: .fetch(Self.notes), .beforeReading)
		let straggler = HeldReadLog(
			inner: observer, holding: .fetch(Self.conversation), .beforeReading, armed: false)
		let outcome = HeldAppendLog(inner: straggler, holding: "reviewOutcome", occurrence: 1)
		defer {
			outcome.release()
			straggler.release()
			observer.release()
		}
		let (coach, turn) = try await blockedCoach(over: outcome, observer: observer)
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
		#expect(
			try canceledClosing(in: shown, after: turn) == "The remaining changes were canceled.")
	}

	@Test func aCancelLeavesTheNoteAndNoCardWhenANewerReviewReadFailsAtTheDesk() async throws {
		let faults = FaultInjectingRecordLog(wrapping: turns.store)
		let observer = HeldReadLog(inner: faults, holding: .fetch(Self.notes), .beforeReading)
		let decidePath = HeldReadLog(
			inner: observer, holding: .fetch(Self.outcomes), .afterReading, armed: false)
		let outcome = HeldAppendLog(inner: decidePath, holding: "reviewOutcome", occurrence: 1)
		defer {
			outcome.release()
			decidePath.release()
			observer.release()
		}
		let (coach, turn) = try await blockedCoach(over: outcome, observer: observer)
		let blocked = try #require(try await coach.desk.snapshot(chat: .main))
		let cancel = try await armedToken(on: coach)

		async let canceling = coach.decide(.cancel(cancel), in: .main)
		try await outcome.waitUntilReached()
		decidePath.arm()
		outcome.release()
		try await decidePath.waitUntilReached()
		faults.failNextFetch(in: Self.outcomes.scope)
		_ = await coach.decide(.presented(blocked.ref), in: .main)
		#expect(faults.failedFetchCount == 1)
		decidePath.release()
		guard case .canceled = await canceling else {
			Issue.record("the blocked review was not canceled")
			return
		}

		let shown = try #require(await coach.currentSnapshot(.main))
		#expect(shown.review == nil)
		#expect(
			try canceledClosing(in: shown, after: turn) == "The remaining changes were canceled.")
	}

	@Test func aRefreshAfterTheCancelShowsTheNoteAndNoCardWhenAnotherReadOvertookIt()
		async throws
	{
		let observer = HeldReadLog(inner: turns.store, holding: .fetch(Self.notes), .beforeReading)
		let refreshing = HeldReadLog(
			inner: observer, holding: .fetch(Self.conversation), .beforeReading, armed: false)
		let decidePath = HeldReadLog(
			inner: refreshing, holding: .fetch(Self.notes), .afterReading, armed: false)
		let outcome = HeldAppendLog(inner: decidePath, holding: "reviewOutcome", occurrence: 1)
		defer {
			outcome.release()
			decidePath.release()
			refreshing.release()
			observer.release()
		}
		let (coach, turn) = try await blockedCoach(over: outcome, observer: observer)
		let blocked = try #require(try await coach.desk.snapshot(chat: .main))
		let cancel = try await armedToken(on: coach)
		let mailbox = try await coach.mailbox(for: .main)

		async let canceling = coach.decide(.cancel(cancel), in: .main)
		try await outcome.waitUntilReached()
		refreshing.arm()
		async let refreshed: Void = mailbox.refreshImports()
		try await refreshing.waitUntilReached()
		_ = await coach.decide(.presented(blocked.ref), in: .main)
		#expect(await coach.currentSnapshot(.main)?.review?.ref.review == blocked.ref.review)
		decidePath.arm()
		outcome.release()
		try await decidePath.waitUntilReached()
		refreshing.release()
		try await refreshed

		let shown = try #require(await coach.currentSnapshot(.main))
		#expect(shown.review == nil)
		#expect(
			try canceledClosing(in: shown, after: turn) == "The remaining changes were canceled.")
		decidePath.release()
		guard case .canceled = await canceling else {
			Issue.record("the blocked review was not canceled")
			return
		}
		#expect(await coach.currentSnapshot(.main)?.review == nil)
	}

	private func blockedCoach(over log: any ReviewChainLog, observer: HeldReadLog) async throws
		-> (Coach, TurnID)
	{
		let coach = await turns.coach(over: log)
		await coach.lifecycle(.becameActive)
		_ = await coach.observe(.main)
		await coach.desk.moved(.main)
		try await observer.waitUntilReached()
		let review = try await turns.committed(ReviewTurns.fourChanges, on: coach)
		turns.intervals.events.removeAll { $0.id == EventID(rawValue: 202) }
		let approve = try await armedToken(on: coach)
		#expect(await coach.decide(.approve(approve), in: .main) == .blocked(.cannotVerify))
		return (coach, review.origin.turn)
	}

	private func canceledClosing(in shown: ChatSnapshot, after turn: TurnID) throws -> String? {
		try #require(shown.notes[turn]?.last).closing(in: displayLocale())
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
