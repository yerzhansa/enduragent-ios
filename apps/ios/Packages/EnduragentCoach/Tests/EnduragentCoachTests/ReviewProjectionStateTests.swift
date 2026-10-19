import EnduragentCoachFixtures
import Foundation
import Synchronization
import Testing

@testable import EnduragentCoach

@Suite struct ReviewProjectionStateTests {
	static let english = displayLocale()
	static let partial =
		"intervals.icu refused a change, so the remaining changes were stopped. Changes already made are kept. Check the rest before you try again."
	static let unconfirmed =
		"A change may have been saved to your intervals.icu calendar. Check again to find out before anything else is changed."
	static let sending = "Making the reviewed changes on your intervals.icu calendar…"
	static let missing =
		"A workout in this review is no longer on your intervals.icu calendar, so this review can't continue. Cancel it and ask the coach again."
	static let stopped =
		"This workout review stopped before every change was made. Changes already made are kept."

	@Test func aRefusedChangeKeepsTheFinishedApartOffersTryAgainAndEndsWithAClosingLine()
		async throws
	{
		let rig = DeskRig()
		try await rig.save(try rig.mixed())
		rig.calendar.answer { index, write in
			if index == 2 { return .httpStatus(400) }
			if case .delete = write { return .httpStatus(404) }
			return nil
		}
		let desk = try rig.desk()
		guard case .stopped = await desk.decide(.approve(try await rig.token(on: desk))) else {
			Issue.record("the refused edit did not stop the review")
			return
		}
		let token = try await rig.token(on: desk)
		let partial = try #require(try await desk.snapshot(chat: .main))

		#expect(partial.controls == .armed(.tryAgainOrCancel, token))
		#expect(partial.notice?.sentences(in: Self.english) == [Self.partial])
		#expect(
			partial.cards.compactMap { $0.finishedLine(in: Self.english) } == [
				"Tempo ride, 9/9/1998: change saved.",
				"Strength, 9/10/1998: change saved.",
			])
		#expect(
			partial.cards.filter { $0.finishedLine(in: Self.english) == nil }.map(\.progress) == [
				.refused, .remaining,
			])

		guard case .completed = await desk.decide(.tryAgain(token)) else {
			Issue.record("Try again did not complete the review")
			return
		}

		let head = try #require(try await rig.head().1)
		#expect(ReviewProjection.notice(of: head) == .completed)
		#expect(try await desk.snapshot(chat: .main) == nil)
		let note = try #require(try await Self.notes(rig).last)
		#expect(
			note.sentence(in: Self.english)
				== [
					"Tempo ride, 9/9/1998: change saved.",
					"Strength, 9/10/1998: change saved.",
					"Endurance, 9/10/1998: change saved.",
					"Recovery, 9/11/1998: no longer on the calendar.",
				].joined(separator: "\n"))
		#expect(note.closing(in: Self.english) == "All reviewed changes are complete.")
	}

	@Test func aLostAnswerReadsAsMayHaveBeenSavedUntilCheckAgainSeesItOnTheCalendar()
		async throws
	{
		let rig = DeskRig()
		try await rig.save(try rig.mixed())
		rig.calendar.answer { [rig] index, write in
			guard index == 0 else { return nil }
			_ = await rig.keep(write)
			rig.calendar.failReads()
			return .lost(.transport)
		}
		let desk = try rig.desk()
		guard case .unconfirmed = await desk.decide(.approve(try await rig.token(on: desk))) else {
			Issue.record("the lost answer did not leave the change unconfirmed")
			return
		}
		let checkAgain = try await rig.token(on: desk)
		let unconfirmed = try #require(try await desk.snapshot(chat: .main))

		#expect(unconfirmed.controls == .armed(.checkAgainOrCancel, checkAgain))
		#expect(unconfirmed.notice?.sentences(in: Self.english) == [Self.unconfirmed])
		#expect(unconfirmed.cards[0].status(in: Self.english) == "May have been saved")
		#expect(unconfirmed.cards.compactMap { $0.finishedLine(in: Self.english) }.isEmpty)

		rig.calendar.restoreReads()
		guard case .stopped = await desk.decide(.checkAgain(checkAgain)) else {
			Issue.record("Check again did not settle the lost answer")
			return
		}
		let tryAgain = try await rig.token(on: desk)
		let settled = try #require(try await desk.snapshot(chat: .main))

		#expect(settled.controls == .armed(.tryAgainOrCancel, tryAgain))
		#expect(settled.notice?.sentences(in: Self.english) == [Self.stopped])
		#expect(settled.cards[0].status(in: Self.english) == "Seen on the calendar")
		#expect(
			settled.cards.compactMap { $0.finishedLine(in: Self.english) } == [
				"Tempo ride, 9/9/1998: change seen on the calendar."
			])
	}

	@Test func aSendingReviewSaysSoWithTheFinishedApartAndNoControl() async throws {
		let rig = DeskRig()
		try await rig.save(try rig.mixed())
		let reader = try rig.desk()
		let seen = SeenSnapshot()
		rig.calendar.observe { touch in
			guard case .write(.create(let payload, _)) = touch, payload.name == "Strength" else {
				return
			}
			do {
				seen.record(try await reader.snapshot(chat: .main))
			} catch {
				Issue.record(error, "the review could not be read while it was sending")
			}
		}
		let desk = try rig.desk()

		guard case .completed = await desk.decide(.approve(try await rig.token(on: desk))) else {
			Issue.record("the review did not complete")
			return
		}

		let sending = try #require(seen.shown)
		#expect(sending.controls == .none)
		#expect(sending.offered == nil)
		#expect(sending.notice?.sentences(in: Self.english) == [Self.sending])
		#expect(
			sending.cards.compactMap { $0.finishedLine(in: Self.english) } == [
				"Tempo ride, 9/9/1998: change saved."
			])
		#expect(sending.cards[1].status(in: Self.english) == "Sending…")
	}

	@Test func aMissingTargetBlocksWithItsReasonAfterARelaunchAndCancelsWithAClosingLine()
		async throws
	{
		let rig = DeskRig()
		try await rig.save(try rig.mixed())
		rig.base.events.removeAll { $0.id == EventID(rawValue: 202) }
		let desk = try rig.desk()

		#expect(
			await desk.decide(.approve(try await rig.token(on: desk))) == .blocked(.cannotVerify))

		let relaunched = try rig.desk()
		let cancel = try await rig.token(on: relaunched)
		let blocked = try #require(try await relaunched.snapshot(chat: .main))
		#expect(blocked.controls == .armed(.cancelOnly, cancel))
		#expect(blocked.notice?.sentences(in: Self.english) == [Self.missing])
		#expect(rig.calendar.writes.isEmpty)

		guard case .canceled = await relaunched.decide(.cancel(cancel)) else {
			Issue.record("the blocked review was not canceled")
			return
		}

		let head = try #require(try await rig.head().1)
		#expect(ReviewProjection.notice(of: head) == .canceled)
		let note = try #require(try await Self.notes(rig).last)
		#expect(note.closing(in: Self.english) == "The remaining changes were canceled.")
	}

	@Test func aStalledSendShowsOnlyTheStorageNoticeAndNoControl() async throws {
		let rig = DeskRig()
		try await rig.save(try rig.mixed())
		let dying = FaultInjectingRecordLog(wrapping: rig.store)
		let desk = try rig.desk(over: dying)
		let token = try await rig.token(on: desk)
		try dying.failAppend(ofKind: DeviceLocalKind.workoutReview.rawValue, skipping: 2)

		#expect(await desk.decide(.approve(token)) == .storageUnavailable)

		let stalled = try #require(try await desk.snapshot(chat: .main))
		#expect(stalled.controls == .none)
		#expect(stalled.notice?.kind == .storageUnavailable)
		#expect(
			stalled.notice?.sentences(in: Self.english) == [
				"Couldn't read the saved workout review. Its buttons are temporarily disabled."
			])
	}

	static func notes(_ rig: DeskRig) async throws -> [TranscriptNote] {
		try await rig.ledger().conversation(.main).current.notes.map {
			TranscriptNote(id: $0.ulid, after: $0.after, content: $0.content)
		}
	}
}

private final class SeenSnapshot: Sendable {
	private let seen = Mutex<ReviewSnapshot?>(nil)

	var shown: ReviewSnapshot? { seen.withLock { $0 } }

	func record(_ snapshot: ReviewSnapshot?) {
		seen.withLock { $0 = snapshot }
	}
}
