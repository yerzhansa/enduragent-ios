import EnduragentCoach
import XCTest

final class ShortcutProof: XCTestCase {
	func testShortcutIsPickedSentWithItsTextAndAnsweredInText() {
		let app = XCUIApplication()
		TutorialHarness.launch(app)
		TutorialHarness.completeOnboarding(app)
		ShortcutScreen.openList(app)
		TutorialHarness.attach(self, name: "shortcut-list", app: app)
		ShortcutScreen.pick(.status, in: app, settledTurns: 0)
		TutorialHarness.attach(self, name: "shortcut-filled", app: app)
		ShortcutScreen.sendAndRead(
			self, app, .status, adding: "how is my Form this week",
			reply: ShortcutScreen.statusReply, turn: 1)
		ShortcutScreen.openList(app)
		ShortcutScreen.pick(.workout, in: app, settledTurns: 1)
		ShortcutScreen.sendAndRead(
			self, app, .workout, adding: ShortcutScreen.workoutRequest,
			reply: ShortcutScreen.workoutReply, turn: 2)
	}

	func testWorkoutLosingModelAccessShowsTheNoticeAndNoReply() {
		let app = XCUIApplication()
		TutorialHarness.launch(app)
		TutorialHarness.completeOnboarding(app)
		let message = "/workout fixture:lost"
		TutorialHarness.exchange(app, message)
		let transcript = TutorialHarness.named(app, "chat.transcript")
		TutorialHarness.wait(transcript.staticTexts[message])
		TutorialHarness.wait(TutorialHarness.notice(app, reading: TutorialHarness.providerDown))
		let actions = app.buttons.matching(identifier: "chat.turn.tryAgain")
		XCTAssertEqual(actions.count, 1)
		XCTAssertEqual(actions.firstMatch.label, TutorialHarness.tryAgain)
		XCTAssertTrue(actions.firstMatch.isEnabled)
		XCTAssertFalse(transcript.staticTexts["chat.working"].exists)
		XCTAssertFalse(TutorialHarness.text(app, containing: ShortcutScreen.lostOpening).exists)
		ShortcutScreen.assertNoReviewAndNoCalendarLine(app)
		TutorialHarness.attach(self, name: "shortcut-interrupted", app: app)
	}
}

final class PlanShortcutProof: XCTestCase {
	func testSlashListShowsPlanAfterWorkout() {
		let app = XCUIApplication()
		TutorialHarness.launch(app)
		TutorialHarness.completeOnboarding(app)
		ShortcutScreen.openList(app)
		let rows = [
			"start", "workout", "plan", "status", "review", "language", "feedback", "version",
		].map { TutorialHarness.named(app, "chat.slash.\($0)") }
		for row in rows { TutorialHarness.wait(row) }
		let tops = rows.map { $0.frame.minY }
		XCTAssertEqual(tops, tops.sorted())
		XCTAssertEqual(Set(tops).count, rows.count)
		let titles = [
			("/feedback", "Send a note to the Enduragent authors"),
			("/version", "Show current version"),
		]
		for (row, (command, title)) in zip(rows.suffix(2), titles) {
			XCTAssertTrue(row.label.hasPrefix(command), row.label)
			XCTAssertTrue(row.label.contains(title), row.label)
		}
		TutorialHarness.attach(self, name: "slash-list-plan", app: app)
	}

	func testPlanForwardsItsTextWithNoAcknowledgement() {
		let app = XCUIApplication()
		TutorialHarness.launch(app)
		TutorialHarness.completeOnboarding(app)
		ShortcutScreen.openList(app)
		ShortcutScreen.pick(.plan, in: app, settledTurns: 0)
		ShortcutScreen.sendAndRead(
			self, app, .plan, adding: ShortcutScreen.planRequest,
			reply: ShortcutScreen.planReply, turn: 1)
		XCTAssertFalse(
			TutorialHarness.text(app, containing: ShortcutScreen.planAcknowledgement).exists)
		XCTAssertFalse(TutorialHarness.named(app, "chat.turn.notice").exists)
	}
}

enum ShortcutScreen {
	static let workoutRequest = "45 minutes indoors"
	static let workoutMessage = "/workout " + workoutRequest
	static let workoutReply = "Ride 45 minutes at an easy endurance pace today."
	static let planRequest = "for my gran fondo in June"
	static let planReply = "the hours you can ride each week"
	static let planAcknowledgement = CatalogPhrasebook(tag: .en).say(Catalog.telegramPlanWorking)
	static let statusReply = "your Fitness is 42 with Fatigue at 49 and Form at -7"
	static let lostOpening = "Ride 45 minutes"
	static let reviewTitle = "Workout review"

	private static let titles: [SlashCommand: String] = [
		.workout: "Get today's workout",
		.plan: "Generate a training plan",
		.status: "Check current fitness, fatigue, and form",
	]

	static func rowIdentifier(_ command: SlashCommand) -> String {
		"chat.slash.\(command.rawValue.dropFirst())"
	}

	static func row(_ command: SlashCommand, in app: XCUIApplication) -> XCUIElement {
		TutorialHarness.named(app, rowIdentifier(command))
	}

	static func openList(_ app: XCUIApplication) {
		let composer = TutorialHarness.named(app, "chat.composer")
		TutorialHarness.wait(composer, until: .hittable)
		composer.tap()
		composer.typeText("/")
		for (command, title) in titles {
			let row = row(command, in: app)
			TutorialHarness.wait(row)
			XCTAssertTrue(row.label.hasPrefix(command.rawValue), row.label)
			XCTAssertTrue(row.label.contains(title), row.label)
		}
	}

	static func pick(_ command: SlashCommand, in app: XCUIApplication, settledTurns: Int) {
		let row = row(command, in: app)
		TutorialHarness.scroll(app, to: row, direction: .down)
		row.tap()
		let filled = command.rawValue + " "
		TutorialHarness.wait(TutorialHarness.named(app, "chat.composer"), until: .value(filled))
		TutorialHarness.wait(row, until: .absent)
		let transcript = TutorialHarness.named(app, "chat.transcript")
		XCTAssertFalse(transcript.staticTexts[command.rawValue].exists)
		XCTAssertFalse(transcript.staticTexts["chat.working"].exists)
		XCTAssertEqual(
			TutorialHarness.named(app, "chat.turnProgress").value as? String,
			"turns \(settledTurns) settled \(settledTurns)")
		XCTAssertEqual(TutorialHarness.named(app, "chat.composer").value as? String, filled)
	}

	static func sendAndRead(
		_ test: XCTestCase, _ app: XCUIApplication, _ command: SlashCommand,
		adding trailing: String, reply: String, turn: Int
	) {
		let name = String(command.rawValue.dropFirst())
		let message = command.rawValue + " " + trailing
		TutorialHarness.send(app, trailing)
		let transcript = TutorialHarness.named(app, "chat.transcript")
		let sent = transcript.staticTexts[message]
		let working = transcript.staticTexts["chat.working"]
		let answer = TutorialHarness.text(app, containing: reply)
		TutorialHarness.wait(sent)
		TutorialHarness.wait(working)
		XCTAssertEqual(working.label, TutorialHarness.working)
		XCTAssertFalse(answer.exists)
		TutorialHarness.attach(test, name: "shortcut-\(name)-working", app: app)
		TutorialHarness.waitForProgress(
			app, to: "the \(command.rawValue) reply starting", within: .turn
		) {
			let stillWorking = working.exists
			if answer.exists { return true }
			XCTAssertTrue(stillWorking, "the working line left before the reply started")
			return false
		}
		TutorialHarness.wait(
			TutorialHarness.named(app, "chat.turnProgress"),
			until: .value("turns \(turn) settled \(turn)"), within: .turn)
		TutorialHarness.wait(working, until: .absent)
		XCTAssertTrue(answer.exists)
		XCTAssertEqual(transcript.staticTexts.matching(identifier: message).count, 1)
		XCTAssertLessThan(sent.frame.minY, answer.frame.minY)
		assertNoReviewAndNoCalendarLine(app)
		TutorialHarness.attach(test, name: "shortcut-\(name)-finished", app: app)
	}

	static func assertNoReviewAndNoCalendarLine(_ app: XCUIApplication) {
		XCTAssertFalse(TutorialHarness.named(app, "chat.preview.add").exists)
		XCTAssertFalse(TutorialHarness.named(app, "chat.preview.cancel").exists)
		XCTAssertFalse(TutorialHarness.named(app, "chat.preview.notice").exists)
		XCTAssertFalse(TutorialHarness.text(app, containing: reviewTitle).exists)
		XCTAssertFalse(TutorialHarness.named(app, "chat.note").exists)
	}
}
