import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

@Suite struct PreparedEarlierTests {
	let turns = ReviewTurns()
	let calendar: ScriptedCalendar
	let english = displayLocale()

	init() {
		calendar = ScriptedCalendar(turns.intervals)
	}

	@Test func aWaitingReviewShowsOnceAtTheTopOfTheNewConversationAndCanBeApproved()
		async throws
	{
		let coach = await coach()
		let review = try await turns.committed(ReviewTurns.oneRide, on: coach)
		let before = try #require(try await coach.desk.snapshot(chat: .main))
		#expect(before.placement == .afterTurn(review.origin.turn))
		#expect(before.placement.notice == nil)

		guard case .started = await coach.resetAndSettle(in: .main) else {
			Issue.record("New conversation did not start")
			return
		}

		let after = try #require(try await coach.desk.snapshot(chat: .main))
		#expect(after.placement == .preparedEarlier)
		#expect(after.ref.review == review.id)
		#expect(after.ref.revision == review.revision)
		#expect(after.placement.notice.map { english.say($0) } == "Prepared earlier")
		#expect(await coach.currentSnapshot(.main)?.turns.isEmpty == true)
		#expect(await coach.desk.decide(.presented(after.ref)) == .presentationRecorded)
		guard
			case .armed(.approveOrCancel, let token) = try #require(
				try await coach.desk.snapshot(chat: .main)
			).controls
		else {
			Issue.record("the review prepared earlier never armed Approve")
			return
		}

		guard case .completed = await coach.desk.decide(.approve(token)) else {
			Issue.record("the review prepared earlier was not approved")
			return
		}

		#expect(calendar.writes == review.work.remaining.map(DeskRig.request))
		try await coach.mailbox(for: .main).refreshImports()
		let current = try #require(await coach.currentSnapshot(.main))
		#expect(
			current.notes[nil]?.map { $0.sentence(in: english) } == [
				english.say(
					Catalog.workoutsOutcomeSaved,
					["workout": .text("Threshold 2x2"), "date": .day("1998-09-09")])
			])
		let archived = try await coach.newestArchive()
		#expect(archived.turns.map(\.id) == [review.origin.turn])
		#expect(archived.notes.isEmpty)
	}

	@Test func aReviewPreparedAfterNewConversationStaysAfterItsTurn() async throws {
		let coach = await coach()
		turns.script([.text("Two rides."), .finish(reason: .stop)])
		_ = try await coach.sendAndSettle("How was my week?")
		guard case .started = await coach.resetAndSettle(in: .main) else {
			Issue.record("New conversation did not start")
			return
		}

		let review = try await turns.committed(ReviewTurns.oneRide, on: coach)

		let shown = try #require(try await coach.desk.snapshot(chat: .main))
		#expect(shown.placement == .afterTurn(review.origin.turn))
		#expect(shown.placement.notice == nil)
	}

	private func coach() async -> Coach {
		await makeCoach(
			transport: turns.transport, intervals: calendar, store: turns.store, clock: turns.clock)
	}
}
