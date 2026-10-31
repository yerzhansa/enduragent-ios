import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

@Suite struct ReviewCardLanguageTests {
	let turns = ReviewTurns()

	@Test func authoredStepsOnTheCardFollowTheDisplayLanguageAndKeepItAfterRelaunch()
		async throws
	{
		_ = try await turns.committed(ReviewTurns.fourChanges, on: await turns.coach())
		let relaunched = await turns.coach()
		let cards = try #require(try await relaunched.desk.snapshot(chat: .main)?.content).cards

		#expect(
			cards.map { $0.lines(in: displayLocale(.de, region: "de_DE")) } == [
				["Aufwärmen", "- 5m 55%", "", "Hauptteil", "- 20m 90%"],
				["Easy", "", "Plank 3x45s"],
				["Aufwärmen", "- 10m 55%", "", "Hauptteil", "- 30m 88%"],
				["Steady ride"],
			])
		#expect(
			cards[0].lines(in: displayLocale(.zhHant, region: "zh_TW")) == [
				"暖身", "- 5m 55%", "", "主要訓練", "- 20m 90%",
			])
		#expect(
			cards[2].lines(in: displayLocale()) == [
				"Warmup", "- 10m 55%", "", "Main set", "- 30m 88%",
			])
	}

	static let languages = [(LanguageTag.de, "de_DE"), (.ptPT, "pt_PT"), (.zhHant, "zh_TW")]

	@Test(arguments: languages)
	func everyLineOfAReviewAndItsProgressReadsInTheDisplayLanguage(
		_ tag: LanguageTag, _ region: String
	) async throws {
		let today: CivilDate = "1998-09-08"
		turns.intervals.events = []
		WorkoutReviewFixture.seed(turns.intervals, today: today)
		let coach = await makeCoach(
			transport: turns.transport, intervals: ScriptedCalendar(turns.intervals),
			store: turns.store, clock: turns.clock)
		_ = try await turns.reply(
			after: [
				.toolCall(
					name: "prepare_workout_changes",
					arguments: WorkoutReviewFixture.mixed(today: today))
			], on: coach)
		let shown = try #require(try await coach.desk.snapshot(chat: .main))

		let lines = { (display: DisplayLocale) -> [String] in
			var presentation = ReviewPresentation(of: shown)
			let unseen = presentation.status(of: shown, in: display)
			_ = presentation.failed(try #require(shown.cards.last), of: shown)
			return
				shown.cards.flatMap { card in
					[card.heading(of: shown.cards.count, in: display)] + card.changes(in: display)
						+ [card.load(in: display)].compactMap { $0 }
				}
				+ [
					display.say(Catalog.reviewTitle), display.say(Catalog.workoutsKeptTitle),
					shown.totals.line(in: display), shown.content.question(in: display),
					display.say(shown.content.approveTitle), display.say(Catalog.commonCancel),
					display.say(Catalog.workoutsBarShowAgain),
				] + [unseen, presentation.status(of: shown, in: display)].compactMap { $0 }
		}

		try Self.expectTranslated(
			try lines(displayLocale(tag, region: region)),
			try lines(displayLocale(.en, region: region)),
			count: 20, in: tag)
	}

	@Test(arguments: languages)
	func everyStageNoticeFinishedLineAndClosingLineReadsInTheDisplayLanguage(
		_ tag: LanguageTag, _ region: String
	) async throws {
		let stages = try await ReviewStageScreens.reached()

		#expect(stages.map(\.name) == ReviewStageScreens.names)
		try Self.expectTranslated(
			stages.flatMap { $0.lines(in: displayLocale(tag, region: region)) },
			stages.flatMap { $0.lines(in: displayLocale(.en, region: region)) }, count: 30,
			in: tag)
	}

	static func expectTranslated(
		_ shown: [String], _ english: [String], count: Int, in tag: LanguageTag
	) throws {
		#expect(shown.count == count)
		try #require(shown.count == english.count)
		for (line, source) in zip(shown, english) {
			#expect(line != source, "[\(tag.rawValue)] still reads English: \(line)")
			#expect(!line.contains("{{") && !line.contains("}}"), "[\(tag.rawValue)] \(line)")
		}
	}
}
