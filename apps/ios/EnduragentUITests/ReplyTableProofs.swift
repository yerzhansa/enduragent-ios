import EnduragentCoach
import EnduragentCoachFixtures
import XCTest

@MainActor
final class ReplyTableProof: XCTestCase {
	func testNumbersTablesStackScrollAndReadRowByRowInChatAndHistory() {
		let app = XCUIApplication()
		TutorialHarness.launch(app)
		TutorialHarness.completeOnboarding(app)
		TutorialHarness.exchange(app, "fixture:numbers")
		ReplyProofScreen.assertDocument(app, source: NumbersReplyFixture.source)
		let chat = ReplyProofScreen.labels(app)
		ReplyTableScreen.assertSummaryFitsTheReply(app)
		TutorialHarness.attach(self, name: "reply-table-summary", app: app)
		ReplyTableScreen.assertEachLapRowDrawsOneSeparator(app)
		TutorialHarness.attach(self, name: "reply-table-laps-separators", app: app)
		ReplyTableScreen.assertLapTableScrollsToItsLastColumn(app)
		TutorialHarness.attach(self, name: "reply-table-laps-last-column", app: app)
		TutorialHarness.startNewConversation(app)
		ReplyProofScreen.openArchive(app)
		ReplyProofScreen.assertDocument(app, source: NumbersReplyFixture.source)
		XCTAssertEqual(ReplyProofScreen.labels(app), chat)
		ReplyTableScreen.assertSummaryFitsTheReply(app)
		TutorialHarness.attach(self, name: "reply-table-history", app: app)
		TutorialHarness.returnToChat(app)
	}

	func testArrivedRowsKeepTheirLabelsWhileTheReplyIsHeldAndAfterStop() {
		let app = XCUIApplication()
		TutorialHarness.launch(app)
		TutorialHarness.completeOnboarding(app)
		TutorialHarness.send(app, "fixture:numbers-held")
		let arrived = ReplyProofScreen.tables(NumbersReplyFixture.held).flatMap {
			ReplyProofScreen.spoken($0.rowDescriptions)
		}
		TutorialHarness.wait(
			until: { ReplyProofScreen.labels(app)["reply.table.row"] == arrived },
			within: .turn, message: "The held numbers reply did not finish arriving")
		XCTAssertTrue(TutorialHarness.named(app, "chat.working").exists)
		TutorialHarness.attach(self, name: "reply-table-held", app: app)
		let stop = TutorialHarness.named(app, "chat.stop")
		TutorialHarness.wait(stop, until: .hittable)
		stop.tap()
		TutorialHarness.wait(
			TutorialHarness.named(app, "chat.working"), until: .absent, within: .turn)
		TutorialHarness.waitForLabel(app, TutorialHarness.interruptedNothingChanged)
		XCTAssertFalse(
			TutorialHarness.notice(app, reading: TutorialHarness.providerDown).exists,
			"the fixture watchdog ended the reply before Stop did")
		ReplyProofScreen.assertDocument(app, source: NumbersReplyFixture.held)
		ReplyTableScreen.assertSummaryFitsTheReply(app)
		TutorialHarness.attach(self, name: "reply-table-stopped", app: app)
	}
}

@MainActor
enum ReplyTableScreen {
	static func assertSummaryFitsTheReply(_ app: XCUIApplication) {
		guard let summary = ReplyProofScreen.tables(NumbersReplyFixture.source).first else {
			XCTFail("The numbers fixture must start with its summary table")
			return
		}
		let opening = text(app, "reply.paragraph", "Here are the numbers for the Saturday ride.")
		TutorialHarness.scroll(app, to: opening, direction: .down)
		let reply = opening.frame
		let screen = app.windows.firstMatch.frame
		let lines =
			[line(app, "reply.table.header", summary.headerDescription)]
			+ summary.rowDescriptions.map { line(app, "reply.table.row", $0) }
		var top = -CGFloat.infinity
		for line in lines {
			XCTAssertTrue(line.exists, "\(line) is missing")
			let frame = line.frame
			XCTAssertEqual(frame.minX, reply.minX, accuracy: 1)
			XCTAssertLessThanOrEqual(frame.maxX, screen.maxX - reply.minX + 1)
			XCTAssertGreaterThan(frame.width, screen.width / 2)
			XCTAssertGreaterThan(frame.minY, top)
			top = frame.minY
		}
	}

	static func assertEachLapRowDrawsOneSeparator(_ app: XCUIApplication) {
		guard let laps = ReplyProofScreen.tables(NumbersReplyFixture.source).last else {
			XCTFail("The numbers fixture must end with its lap table")
			return
		}
		let header = line(app, "reply.table.header", laps.headerDescription)
		let lines = [header] + laps.rowDescriptions.map { line(app, "reply.table.row", $0) }
		TutorialHarness.bringIntoTranscript(app, header, topShare: 0.45)
		let band = TutorialHarness.transcriptBand(app)
		let table = app.scrollViews.matching(identifier: "reply.table").firstMatch.frame
		guard let ink = ScreenInk(app) else { return }
		for line in lines {
			XCTAssertTrue(line.exists, "\(line) is missing")
			let frame = line.frame
			XCTAssertGreaterThanOrEqual(
				frame.minY, band.minY, "\(line.label) is above the transcript")
			XCTAssertLessThanOrEqual(
				frame.maxY + 3, band.maxY, "\(line.label) is below the transcript")
			let start = max(frame.minX, table.minX) + 1
			let end = min(frame.maxX, table.maxX) - 1
			XCTAssertGreaterThan(end - start, table.width / 2, "\(line.label) is not on the screen")
			let bare = ink.bareColumns(under: frame.maxY, from: start, to: end)
			if let first = bare.first {
				XCTFail(
					"\(line.label) has no separator along its bottom edge at \(bare.count) pixel "
						+ "columns, the first at x \(first)")
			}
		}
	}

	static func assertLapTableScrollsToItsLastColumn(_ app: XCUIApplication) {
		let table = app.scrollViews.matching(identifier: "reply.table").firstMatch
		TutorialHarness.scroll(app, to: table)
		assertLapTableReachesItsLastColumn(app) { table.swipeLeft(velocity: .slow) }
	}

	static func assertLapTableReachesItsLastColumn(
		_ app: XCUIApplication, swipe: @escaping () -> Void
	) {
		guard let laps = ReplyProofScreen.tables(NumbersReplyFixture.source).last else {
			XCTFail("The numbers fixture must end with its lap table")
			return
		}
		let table = app.scrollViews.matching(identifier: "reply.table").firstMatch
		let header = line(app, "reply.table.header", laps.headerDescription)
		let rows = laps.rowDescriptions.map { line(app, "reply.table.row", $0) }
		XCTAssertGreaterThan(header.frame.maxX, table.frame.maxX)
		TutorialHarness.wait(
			until: {
				if header.frame.maxX <= table.frame.maxX + 1 { return true }
				swipe()
				return header.frame.maxX <= table.frame.maxX + 1
			}, within: .longTurn, message: "The lap table did not scroll to its last column")
		XCTAssertLessThan(header.frame.minX, table.frame.minX)
		var bottom = header.frame.maxY
		for row in rows {
			XCTAssertTrue(row.exists, "\(row) is missing")
			XCTAssertEqual(row.frame.minX, header.frame.minX, accuracy: 1)
			XCTAssertEqual(row.frame.maxX, header.frame.maxX, accuracy: 1)
			XCTAssertGreaterThanOrEqual(row.frame.minY, bottom - 1)
			bottom = row.frame.maxY
		}
	}

	private static func text(_ app: XCUIApplication, _ identifier: String, _ label: String)
		-> XCUIElement
	{
		app.descendants(matching: .any).matching(
			NSPredicate(format: "identifier == %@ AND label == %@", identifier, label)
		).firstMatch
	}

	static func line(
		_ app: XCUIApplication, _ identifier: String, _ description: ReplyRowDescription
	) -> XCUIElement {
		text(app, identifier, description.accessibilityText)
	}
}

@MainActor
private struct ScreenInk {
	private static let contrast = 16.0
	private let rgba: [UInt8]
	private let width: Int
	private let height: Int
	private let scale: CGFloat

	init?(_ app: XCUIApplication) {
		let screenshot = app.screenshot()
		guard let image = screenshot.image.cgImage,
			let rgba = TutorialHarness.rgba(screenshot, width: image.width, height: image.height)
		else {
			XCTFail("could not read the screenshot pixels")
			return nil
		}
		self.rgba = rgba
		width = image.width
		height = image.height
		scale = CGFloat(image.width) / app.frame.width
	}

	func bareColumns(under bottom: CGFloat, from start: CGFloat, to end: CGFloat) -> [CGFloat] {
		let above = row(bottom - 3)
		let below = row(bottom + 2)
		let edge = row(bottom - 1.5)...row(bottom + 0.5)
		return stride(from: column(start), through: column(end), by: 1).filter { x in
			!edge.contains { y in
				let drawn = luminance(x, y)
				return abs(drawn - luminance(x, above)) > Self.contrast
					&& abs(drawn - luminance(x, below)) > Self.contrast
			}
		}.map { CGFloat($0) / scale }
	}

	private func row(_ points: CGFloat) -> Int {
		min(max(Int((points * scale).rounded()), 0), height - 1)
	}

	private func column(_ points: CGFloat) -> Int {
		min(max(Int((points * scale).rounded()), 0), width - 1)
	}

	private func luminance(_ x: Int, _ y: Int) -> Double {
		TutorialHarness.luminance(rgba, at: (y * width + x) * 4)
	}
}
