import XCTest

final class ToolProgressProof: XCTestCase {
	func testToolProgress() {
		ToolProgressScenario.run(self, dark: false)
	}
}

final class ToolProgressDarkProof: XCTestCase {
	func testToolProgressDark() {
		ToolProgressScenario.run(self, dark: true)
	}
}

private enum ToolProgressScenario {
	static func run(_ test: XCTestCase, dark: Bool) {
		let app = XCUIApplication()
		TutorialHarness.launch(app)
		TutorialHarness.completeOnboarding(app)
		TutorialHarness.send(app, "fixture:slow-tool")
		let transcript = TutorialHarness.named(app, "chat.transcript")
		let question = transcript.staticTexts["fixture:slow-tool"]
		let working = transcript.staticTexts["chat.working"]
		TutorialHarness.wait(question)
		TutorialHarness.wait(working)
		XCTAssertEqual(working.label, TutorialHarness.working)
		XCTAssertFalse(TutorialHarness.text(app, containing: "Checking your recent rides.").exists)
		TutorialHarness.attach(test, name: "tool-progress-model-wait", app: app)
		TutorialHarness.waitForLabel(app, "Checking your recent rides.", within: .turn)
		XCTAssertTrue(working.exists)
		XCTAssertFalse(TutorialHarness.text(app, containing: "I've prepared the ride.").exists)
		if dark {
			XCTAssertLessThan(TutorialHarness.meanLuminance(app.screenshot()), 0.4)
		}
		TutorialHarness.attach(test, name: "tool-progress-read-wait", app: app)
		TutorialHarness.openHistory(app)
		TutorialHarness.waitForLabel(
			app, "No past conversations yet. Starting a new conversation keeps the old one here.")
		TutorialHarness.attach(test, name: "tool-progress-history", app: app)
		TutorialHarness.returnToChat(app)
		TutorialHarness.wait(question)
		XCTAssertTrue(working.exists)
		XCTAssertFalse(TutorialHarness.text(app, containing: "I've prepared the ride.").exists)
		TutorialHarness.attach(test, name: "tool-progress-returned", app: app)
		TutorialHarness.wait(
			TutorialHarness.named(app, "chat.turnProgress"), until: .value("turns 1 settled 1"),
			within: .turn)
		TutorialHarness.wait(working, until: .absent)
		let add = TutorialHarness.named(app, "chat.preview.add")
		TutorialHarness.wait(add, until: .enabled)
		XCTAssertTrue(TutorialHarness.named(app, "chat.preview.cancel").isEnabled)
		TutorialHarness.attach(test, name: "tool-progress-review", app: app)
		TutorialHarness.scroll(app, to: question, direction: .down)
		let questionRow = transcript.cells.containing(.staticText, identifier: "fixture:slow-tool")
			.firstMatch
		let reply = questionRow.staticTexts.containing(
			NSPredicate(format: "label CONTAINS %@", "I've prepared the ride. Confirm to add it.")
		).firstMatch
		TutorialHarness.wait(reply)
		let review = transcript.staticTexts["Workout review"]
		TutorialHarness.wait(review)
		XCTAssertEqual(transcript.staticTexts.matching(identifier: "fixture:slow-tool").count, 1)
		XCTAssertLessThan(question.frame.minY, reply.frame.minY)
		XCTAssertLessThan(reply.frame.maxY, review.frame.minY)
		XCTAssertFalse(working.exists)
		TutorialHarness.attach(test, name: "tool-progress-question-and-reply", app: app)
		TutorialHarness.assertZeroFixtureRequests(app)
	}
}
