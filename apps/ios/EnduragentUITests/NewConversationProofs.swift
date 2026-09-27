import XCTest

final class SlashStartProof: XCTestCase {
	func testSlashStart() {
		let app = XCUIApplication()
		TutorialHarness.launch(app)
		TutorialHarness.completeOnboarding(app)
		TutorialHarness.send(app, TutorialHarness.weekQuestion)
		TutorialHarness.waitForLabel(app, TutorialHarness.weekReply)
		TutorialHarness.send(app, "/start")
		TutorialHarness.waitForWelcome(app)
		let notice = TutorialHarness.named(app, "chat.newConversation.notice")
		TutorialHarness.wait(notice)
		XCTAssertEqual(notice.label, TutorialHarness.newConversationStarted)
		XCTAssertFalse(app.staticTexts["/start"].exists)
		TutorialHarness.attach(self, name: "slash-start", app: app)
		TutorialHarness.openRecords(app)
		XCTAssertEqual(TutorialHarness.recordCount(app, "userMessage"), "userMessage 1")
		XCTAssertEqual(TutorialHarness.recordCount(app, "flushPending"), "flushPending 1")
		XCTAssertEqual(TutorialHarness.recordCount(app, "windowStart"), "windowStart 1")
		TutorialHarness.attach(self, name: "slash-start-records", app: app)
	}
}

final class ResetKeepsReviewProof: XCTestCase {
	func testResetKeepsReview() {
		let app = XCUIApplication()
		TutorialHarness.launch(app)
		TutorialHarness.completeOnboarding(app)
		TutorialHarness.send(app, TutorialHarness.workout)
		TutorialHarness.wait(TutorialHarness.named(app, "chat.preview.add"))
		TutorialHarness.waitForLabel(app, "Confirmed preview")
		TutorialHarness.startNewConversation(app)
		TutorialHarness.waitForLabel(app, TutorialHarness.newConversationStarted)
		XCTAssertTrue(TutorialHarness.named(app, "chat.preview.add").exists)
		XCTAssertTrue(TutorialHarness.named(app, "chat.preview.cancel").exists)
		TutorialHarness.waitForLabel(app, "Confirmed preview")
		TutorialHarness.attach(self, name: "reset-keeps-review", app: app)
		TutorialHarness.openRecords(app)
		XCTAssertEqual(TutorialHarness.recordCount(app, "pendingProposal"), "pendingProposal 1")
		XCTAssertNil(TutorialHarness.recordCount(app, "proposalCleared"))
		XCTAssertEqual(TutorialHarness.recordCount(app, "windowStart"), "windowStart 1")
		TutorialHarness.attach(self, name: "reset-keeps-review-records", app: app)
	}
}

final class PartialFlushResetProof: XCTestCase {
	func testPartialFlushReset() {
		let app = XCUIApplication()
		TutorialHarness.launch(app)
		TutorialHarness.completeOnboarding(app)
		TutorialHarness.exchange(app, "fixture:flush-partial")
		TutorialHarness.startNewConversation(app)
		let notice = TutorialHarness.named(app, "chat.newConversation.notice")
		TutorialHarness.wait(notice)
		XCTAssertEqual(notice.label, TutorialHarness.newConversationMemoryWarning)
		TutorialHarness.attach(self, name: "partial-flush", app: app)
		TutorialHarness.openRecords(app)
		XCTAssertEqual(TutorialHarness.recordCount(app, "flushPending"), "flushPending 1")
		XCTAssertNil(TutorialHarness.recordCount(app, "flushSettled"))
		XCTAssertEqual(TutorialHarness.recordCount(app, "memorySection"), "memorySection 1")
		XCTAssertEqual(TutorialHarness.recordCount(app, "windowStart"), "windowStart 1")
		TutorialHarness.attach(self, name: "partial-flush-records", app: app)
	}
}

final class PlanFreeTextProof: XCTestCase {
	func testPlanIsFreeText() {
		let app = XCUIApplication()
		TutorialHarness.launch(app)
		TutorialHarness.completeOnboarding(app)
		TutorialHarness.send(app, "/plan")
		TutorialHarness.wait(app.staticTexts["/plan"])
		TutorialHarness.waitForLabel(app, TutorialHarness.weekReply)
		XCTAssertFalse(TutorialHarness.named(app, "chat.error").exists)
		XCTAssertFalse(TutorialHarness.named(app, "chat.welcome").exists)
		TutorialHarness.attach(self, name: "plan-free-text", app: app)
		TutorialHarness.assertZeroFixtureRequests(app)
	}
}

final class WelcomeAfterSkipProof: XCTestCase {
	func testWelcomeAfterSkip() {
		let app = XCUIApplication()
		TutorialHarness.launch(app)
		TutorialHarness.waitForLabel(app, TutorialHarness.notice)
		TutorialHarness.named(app, "notice.continue").tap()
		let skip = TutorialHarness.named(app, "connect.skip")
		TutorialHarness.wait(skip)
		skip.tap()
		TutorialHarness.wait(TutorialHarness.named(app, "starter.start"))
		TutorialHarness.named(app, "starter.start").tap()
		TutorialHarness.waitForWelcome(app)
		let welcome = TutorialHarness.named(app, "chat.welcome")
		XCTAssertFalse(welcome.label.contains("/sync"))
		XCTAssertTrue(welcome.label.contains("/workout"))
		TutorialHarness.attach(self, name: "welcome-after-skip", app: app)
	}
}
