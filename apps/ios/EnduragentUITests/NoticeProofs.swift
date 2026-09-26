import XCTest

final class NoticeCopyProof: XCTestCase {
	func testNoticeCopy() {
		let app = XCUIApplication()
		TutorialHarness.launch(app)
		TutorialHarness.completeOnboarding(app)
		TutorialHarness.send(app, "fixture:fail 402")
		TutorialHarness.wait(TutorialHarness.notice(app, reading: TutorialHarness.creditsExhausted))
		let buy = TutorialHarness.named(app, "chat.turn.buyCredits")
		XCTAssertEqual(buy.label, TutorialHarness.buyCredits)
		XCTAssertFalse(TutorialHarness.named(app, "chat.turn.tryAgain").exists)
		TutorialHarness.attach(self, name: "notice-copy-credits-exhausted", app: app)
		buy.tap()
		let balance = TutorialHarness.named(app, "credits.balance")
		TutorialHarness.wait(balance)
		XCTAssertEqual(balance.label, "200 credits")
		TutorialHarness.attach(self, name: "notice-copy-buy-credits-opens-credits", app: app)
		app.navigationBars.buttons.element(boundBy: 0).tap()
		TutorialHarness.send(app, "fixture:fail 401")
		TutorialHarness.wait(TutorialHarness.notice(app, reading: TutorialHarness.accessRejected))
		XCTAssertEqual(
			TutorialHarness.named(app, "chat.turn.restorePurchases").label,
			TutorialHarness.restorePurchases)
		XCTAssertFalse(TutorialHarness.named(app, "chat.turn.tryAgain").exists)
		TutorialHarness.attach(self, name: "notice-copy-access-rejected", app: app)
		TutorialHarness.send(app, "fixture:memory-then-fail")
		TutorialHarness.wait(TutorialHarness.notice(app, reading: TutorialHarness.savedUnverified))
		XCTAssertFalse(TutorialHarness.named(app, "chat.turn.tryAgain").exists)
		TutorialHarness.attach(self, name: "notice-copy-saved-unverified", app: app)
		TutorialHarness.assertZeroFixtureRequests(app)
	}
}

final class AccessNoticeProof: XCTestCase {
	func testNotConfiguredOpensTheConnectStep() {
		let app = XCUIApplication()
		TutorialHarness.launch(app, keychain: "empty")
		TutorialHarness.completeOnboarding(app)
		TutorialHarness.send(app, TutorialHarness.weekQuestion)
		TutorialHarness.wait(TutorialHarness.notice(app, reading: TutorialHarness.notConfigured))
		let choose = TutorialHarness.named(app, "chat.turn.chooseAccessMethod")
		XCTAssertEqual(choose.label, TutorialHarness.chooseAccessMethod)
		XCTAssertFalse(TutorialHarness.named(app, "chat.turn.tryAgain").exists)
		TutorialHarness.attach(self, name: "access-not-configured", app: app)
		choose.tap()
		TutorialHarness.wait(TutorialHarness.named(app, "connect.apiKey"))
		TutorialHarness.attach(self, name: "access-not-configured-connect", app: app)
	}

	func testLockedKeepsTheMessageAndOffersTryAgain() {
		let app = XCUIApplication()
		TutorialHarness.launch(app, keychain: "locked")
		TutorialHarness.completeOnboarding(app)
		TutorialHarness.send(app, TutorialHarness.weekQuestion)
		TutorialHarness.wait(TutorialHarness.notice(app, reading: TutorialHarness.locked))
		XCTAssertTrue(TutorialHarness.named(app, "chat.turn.tryAgain").exists)
		XCTAssertTrue(app.staticTexts[TutorialHarness.weekQuestion].exists)
		TutorialHarness.attach(self, name: "access-locked", app: app)
		TutorialHarness.assertZeroFixtureRequests(app)
	}
}
