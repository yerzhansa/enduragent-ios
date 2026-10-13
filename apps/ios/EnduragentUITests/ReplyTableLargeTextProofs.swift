import EnduragentCoach
import EnduragentCoachFixtures
import XCTest

@MainActor
final class ReplyTableLargeTextProof: XCTestCase {
	func testGermanNumbersStayWholeAtTheLargestTextSize() {
		ReplyTableLargeText.prove(self, .de, region: "de_DE")
	}

	func testPortugueseOfPortugalNumbersStayWholeAtTheLargestTextSize() {
		ReplyTableLargeText.prove(self, .ptPT, region: "pt_PT")
	}

	func testTraditionalChineseNumbersStayWholeAtTheLargestTextSize() {
		ReplyTableLargeText.prove(self, .zhHant, region: "zh_TW")
	}
}

@MainActor
private enum ReplyTableLargeText {
	static func prove(_ test: XCTestCase, _ language: LanguageTag, region: String) {
		let arguments = FixtureArguments()
		let app = MatrixRun.begin(test, language, arguments: arguments).app
		TutorialHarness.exchange(app, "fixture:numbers")
		ReplyProofScreen.assertDocument(app, source: NumbersReplyFixture.source)
		let standard = ReplyProofScreen.labels(app)
		var regional = arguments
		regional.locale = region
		ReviewAccessibility.reopenAtLargestText(app, regional)
		TutorialHarness.wait(
			until: { ReplyProofScreen.labels(app) == standard }, within: .turn,
			message: "[\(language.rawValue)] the labels at the largest text size differ")
		ReplyProofScreen.assertDocument(app, source: NumbersReplyFixture.source)
		ReplyTableScreen.assertSummaryFitsTheReply(app)
		attach(test, language, "summary-top", app)
		guard let summary = ReplyProofScreen.tables(NumbersReplyFixture.source).first,
			let ending = summary.rowDescriptions.last
		else {
			XCTFail("The numbers fixture must start with its summary table")
			return
		}
		let last = ReplyTableScreen.line(app, "reply.table.row", ending)
		ReplyProofScreen.scroll(
			until: { last.isHittable }, action: { app.swipeUp(velocity: .slow) })
		attach(test, language, "summary-end", app)
		TutorialHarness.scroll(
			app, to: app.scrollViews.matching(identifier: "reply.table").firstMatch)
		attach(test, language, "laps-first-column", app)
		ReplyTableScreen.assertLapTableScrollsToItsLastColumn(app)
		attach(test, language, "laps-last-column", app)
	}

	private static func attach(
		_ test: XCTestCase, _ language: LanguageTag, _ screen: String, _ app: XCUIApplication
	) {
		TutorialHarness.attach(
			test, name: "reply-table-large-\(language.rawValue)-\(screen)", app: app)
	}
}
