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
		let tables = ReplyProofScreen.tables(NumbersReplyFixture.source)
		guard let summary = tables.first, let laps = tables.last,
			let opening = summary.rowDescriptions.first, let ending = summary.rowDescriptions.last
		else {
			XCTFail("The numbers fixture must hold its summary table and its lap table")
			return
		}
		TutorialHarness.bringIntoTranscript(
			app, ReplyTableScreen.line(app, "reply.table.row", opening))
		attach(test, language, "summary-top", app)
		var strides = 0
		let pass = { (table: String) in
			strides += 1
			attach(test, language, "\(table)-pass-\(strides)", app)
		}
		TutorialHarness.bringIntoTranscript(
			app, ReplyTableScreen.line(app, "reply.table.row", ending)
		) { pass("summary") }
		attach(test, language, "summary-end", app)
		let header = ReplyTableScreen.line(app, "reply.table.header", laps.headerDescription)
		TutorialHarness.bringIntoTranscript(app, header, topShare: 0.5)
		attach(test, language, "laps-first-column", app)
		ReplyTableScreen.assertLapTableReachesItsLastColumn(app) {
			let row = header.frame.midY
			TutorialHarness.drag(
				app, from: CGPoint(x: app.frame.width * 0.8, y: row),
				to: CGPoint(x: app.frame.width * 0.2, y: row), pace: .steady)
		}
		attach(test, language, "laps-last-column", app)
		guard let closing = laps.rowDescriptions.last else {
			XCTFail("The lap table of the numbers fixture must hold rows")
			return
		}
		strides = 0
		TutorialHarness.bringIntoTranscript(
			app, ReplyTableScreen.line(app, "reply.table.row", closing)
		) { pass("laps-last-column") }
		attach(test, language, "laps-last-column-end", app)
	}

	private static func attach(
		_ test: XCTestCase, _ language: LanguageTag, _ screen: String, _ app: XCUIApplication
	) {
		TutorialHarness.attach(
			test, name: "reply-table-large-\(language.rawValue)-\(screen)", app: app)
	}
}
