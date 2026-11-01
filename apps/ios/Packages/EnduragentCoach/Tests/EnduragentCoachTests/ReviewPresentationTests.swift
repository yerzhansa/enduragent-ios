import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

@Suite struct ReviewPresentationTests {
	let turns = ReviewTurns()
	let today: CivilDate = "1998-09-08"
	let english = displayLocale()

	@Test func noControlExistsBeforeEveryCardOfTheFortyChangeReviewHasAppeared() async throws {
		let coach = await turns.coach()
		let shown = try await committed(
			WorkoutReviewFixture.strengthSessions(40, today: today), on: coach)
		var presentation = ReviewPresentation(of: shown)

		#expect(shown.cards.count == 40)
		#expect(
			presentation.status(of: shown, in: english) == "Scroll through every card to continue.")
		for card in shown.cards.dropLast() {
			#expect(presentation.appeared(card, of: shown, in: english) == nil)
		}
		#expect(try await controls(of: coach) == ReviewControls.none)

		let last = try #require(shown.cards.last)
		let appeared = presentation.appeared(last, of: shown, in: english)
		let decision = try #require(appeared)
		#expect(decision == .presented(shown.ref))
		#expect(await coach.decide(decision, in: .main) == .presentationRecorded)
		let armed = try #require(try await coach.desk.snapshot(chat: .main))
		guard case .armed(.approveOrCancel, _) = armed.controls else {
			Issue.record("every card appeared, yet the review offers \(armed.controls)")
			return
		}
		#expect(presentation.status(of: armed, in: english) == nil)
		#expect(presentation.appeared(last, of: armed, in: english) == nil)
	}

	@Test func aLastCardThatFailsLeavesNoControlUntilTheReviewIsShownAgainWhole() async throws {
		let coach = await turns.coach()
		let shown = try await committed(
			WorkoutReviewFixture.strengthSessions(40, today: today), on: coach)
		var presentation = ReviewPresentation(of: shown)
		for card in shown.cards.dropLast() {
			_ = presentation.appeared(card, of: shown, in: english)
		}
		let last = try #require(shown.cards.last)

		let failure = presentation.failed(last, of: shown)
		let failed = try #require(failure)
		#expect(failed == .presentationFailed(shown.ref))
		#expect(await coach.decide(failed, in: .main) == .presentationRecorded)
		#expect(presentation.appeared(last, of: shown, in: english) == nil)
		#expect(presentation.delivered(shown) == nil)
		#expect(try await controls(of: coach) == ReviewControls.none)
		#expect(
			presentation.status(of: shown, in: english)
				== "Card 40 of 40 could not be shown. Nothing was changed.")

		let again = presentation.showAgain(shown)
		#expect(again == .showAgain(shown.ref))
		#expect(await coach.decide(again, in: .main) == .presentationRecorded)
		let renewed = try #require(try await coach.desk.snapshot(chat: .main))
		#expect(renewed.ref != shown.ref)
		#expect(presentation.round == 1)
		#expect(presentation.delivered(renewed) == nil)
		#expect(presentation.appeared(last, of: renewed, in: english) == nil)
		for card in renewed.cards.dropLast() {
			#expect(try await controls(of: coach) == ReviewControls.none)
			if let decision = presentation.appeared(card, of: renewed, in: english) {
				#expect(card.index == renewed.cards.count - 2)
				#expect(decision == .presented(renewed.ref))
				_ = await coach.decide(decision, in: .main)
			}
		}
		guard case .armed(.approveOrCancel, _) = try await controls(of: coach) else {
			Issue.record("the review shown again whole has no Approve")
			return
		}
	}

	@Test func aLaterDeliveryOfAPresentedRevisionArmsAtOnceButARevisionStartsOver() async throws {
		let calendar = ScriptedCalendar(turns.intervals)
		let coach = await makeCoach(
			transport: turns.transport, intervals: calendar, store: turns.store,
			clock: turns.clock)
		let shown = try await committed(
			WorkoutReviewFixture.strengthSessions(2, today: today), on: coach)
		var presentation = ReviewPresentation(of: shown)
		var decisions: [ReviewDecision] = []
		for card in shown.cards {
			decisions += [presentation.appeared(card, of: shown, in: english)].compactMap { $0 }
		}
		#expect(decisions == [.presented(shown.ref)])
		_ = await coach.decide(.presented(shown.ref), in: .main)
		guard case .armed(_, let token) = try await controls(of: coach) else {
			Issue.record("the presented review has no control")
			return
		}
		calendar.answer { index, _ in index == 1 ? .httpStatus(400) : nil }
		guard case .stopped = await coach.decide(.approve(token), in: .main) else {
			Issue.record("the refused second add did not stop the run")
			return
		}

		let stopped = try #require(try await coach.desk.snapshot(chat: .main))
		#expect(stopped.ref != shown.ref && stopped.ref.revision == shown.ref.revision)
		#expect(presentation.belongs(to: stopped))
		let delivery = presentation.delivered(stopped)
		let redelivered = try #require(delivery)
		#expect(redelivered == .presented(stopped.ref))
		_ = await coach.decide(redelivered, in: .main)
		guard case .armed(.tryAgainOrCancel, _) = try await controls(of: coach) else {
			Issue.record("the stopped review did not offer Try again")
			return
		}

		let revised = try await committed(
			#"{"preparation":{"kind":"replace","base":{"setId":"\#(stopped.ref.review.ulid.rawValue)","revision":1},"changes":[\#(PreparationFixture.ride(on: "1998-09-12"))]}}"#,
			on: coach)
		#expect(revised.ref.revision != shown.ref.revision)
		#expect(!presentation.belongs(to: revised))
		var fresh = ReviewPresentation(of: revised)
		#expect(fresh.delivered(revised) == nil)
	}

	private func committed(_ arguments: String, on coach: Coach) async throws -> ReviewSnapshot {
		_ = try await turns.reply(
			after: [.toolCall(name: "prepare_workout_changes", arguments: arguments)], on: coach)
		return try #require(try await coach.desk.snapshot(chat: .main))
	}

	private func controls(of coach: Coach) async throws -> ReviewControls {
		try #require(try await coach.desk.snapshot(chat: .main)).controls
	}
}
