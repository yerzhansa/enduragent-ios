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
}
