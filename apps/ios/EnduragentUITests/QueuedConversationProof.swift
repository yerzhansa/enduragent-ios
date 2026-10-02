import XCTest

final class QueuedConversationProof: XCTestCase {
	func testSlashStartKeepsTheOldConversationWhileSendIsFree() {
		proveQueuedConversation(slash: true)
	}

	func testToolbarKeepsTheOldConversationWhileSendIsFree() {
		proveQueuedConversation(slash: false)
	}

	private func proveQueuedConversation(slash: Bool) {
		let app = XCUIApplication()
		TutorialHarness.launch(app)
		TutorialHarness.completeOnboarding(app)
		TutorialHarness.send(app, "fixture:slow-flush")
		TutorialHarness.wait(app.staticTexts["fixture:slow-flush"])
		TutorialHarness.wait(TutorialHarness.named(app, "chat.working"))
		if slash {
			TutorialHarness.send(app, "/start")
		} else {
			TutorialHarness.startNewConversation(app)
		}
		let working = TutorialHarness.named(app, "chat.working")
		XCTAssertEqual(working.label, "Starting a new conversation…")
		XCTAssertTrue(app.staticTexts["fixture:slow-flush"].exists)
		XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "chat.working").count, 1)
		TutorialHarness.attach(self, name: slash ? "queued-slash-reply" : "queued-toolbar-reply", app: app)
		let composer = TutorialHarness.named(app, "chat.composer")
		XCTAssertEqual(composer.value as? String, "Message your coach")
		TutorialHarness.send(app, TutorialHarness.remember)
		XCTAssertFalse(app.staticTexts[TutorialHarness.remember].exists)
		TutorialHarness.waitForLabel(app, TutorialHarness.weekReply)
		XCTAssertEqual(working.label, "Starting a new conversation…")
		XCTAssertTrue(app.staticTexts["fixture:slow-flush"].exists)
		TutorialHarness.attach(self, name: slash ? "queued-slash-memory" : "queued-toolbar-memory", app: app)
		TutorialHarness.waitForWelcome(app)
		TutorialHarness.waitForLabel(app, TutorialHarness.rememberReply)
		XCTAssertTrue(app.staticTexts[TutorialHarness.remember].exists)
		XCTAssertFalse(app.staticTexts["fixture:slow-flush"].exists)
		TutorialHarness.attach(self, name: slash ? "queued-slash-opened" : "queued-toolbar-opened", app: app)
		TutorialHarness.assertZeroFixtureRequests(app)
	}
}
