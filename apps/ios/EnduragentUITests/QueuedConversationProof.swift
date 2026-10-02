import XCTest

final class QueuedConversationProof: XCTestCase {
	func testSlashStartKeepsTheOldConversationWhileSendIsFree() {
		proveQueuedConversation(slash: true)
	}

	func testToolbarKeepsTheOldConversationWhileSendIsFree() {
		proveQueuedConversation(slash: false)
	}

	func testLaterBoundaryFailureKeepsTheOldConversationAndShowsANotice() {
		let app = XCUIApplication()
		TutorialHarness.launch(app, arguments: FixtureArguments(resetFault: .failBoundary))
		TutorialHarness.completeOnboarding(app)
		TutorialHarness.send(app, "fixture:hang")
		TutorialHarness.wait(TutorialHarness.named(app, "chat.working"))
		TutorialHarness.send(app, "/start")
		TutorialHarness.waitForLabel(app, "Starting a new conversation…", within: .probe)
		TutorialHarness.named(app, "chat.stop").tap()
		let notice = TutorialHarness.named(app, "chat.newConversation.notice")
		TutorialHarness.wait(notice)
		XCTAssertEqual(
			notice.label,
			"We couldn’t confirm whether the new conversation started. Your visible conversation is preserved."
		)
		XCTAssertTrue(app.staticTexts["fixture:hang"].exists)
		TutorialHarness.attach(self, name: "queued-reset-failure", app: app)
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
			let button = TutorialHarness.named(app, "chat.newConversation")
			TutorialHarness.wait(button, until: .hittable)
			button.tap()
		}
		let working = TutorialHarness.named(app, "chat.working")
		TutorialHarness.waitForLabel(app, "Starting a new conversation…", within: .probe)
		XCTAssertEqual(working.label, "Starting a new conversation…")
		XCTAssertTrue(app.staticTexts["fixture:slow-flush"].exists)
		XCTAssertEqual(
			app.descendants(matching: .any).matching(identifier: "chat.working").count, 1)
		TutorialHarness.attach(
			self, name: slash ? "queued-slash-reply" : "queued-toolbar-reply", app: app)
		let composer = TutorialHarness.named(app, "chat.composer")
		XCTAssertEqual(composer.value as? String, "")
		TutorialHarness.send(app, TutorialHarness.remember)
		XCTAssertFalse(app.staticTexts[TutorialHarness.remember].exists)
		TutorialHarness.waitForLabel(app, TutorialHarness.weekReply)
		XCTAssertEqual(working.label, "Starting a new conversation…")
		XCTAssertTrue(app.staticTexts["fixture:slow-flush"].exists)
		TutorialHarness.attach(
			self, name: slash ? "queued-slash-memory" : "queued-toolbar-memory", app: app)
		TutorialHarness.waitForWelcome(app)
		TutorialHarness.waitForLabel(app, TutorialHarness.rememberReply)
		XCTAssertTrue(app.staticTexts[TutorialHarness.remember].exists)
		XCTAssertFalse(app.staticTexts["fixture:slow-flush"].exists)
		TutorialHarness.attach(
			self, name: slash ? "queued-slash-opened" : "queued-toolbar-opened", app: app)
		TutorialHarness.assertZeroFixtureRequests(app)
	}
}
