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
		TutorialHarness.named(app, "chat.turn.restorePurchases").tap()
		TutorialHarness.wait(TutorialHarness.named(app, "credits.balance"))
		TutorialHarness.attach(self, name: "notice-copy-restore-purchases-opens-credits", app: app)
		app.navigationBars.buttons.element(boundBy: 0).tap()
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
		TutorialHarness.launch(app)
		TutorialHarness.completeOnboarding(app)
		app.launchArguments += [TutorialHarness.keychainArgument, "locked"]
		TutorialHarness.relaunchKeepingStore(app)
		TutorialHarness.send(app, TutorialHarness.weekQuestion)
		TutorialHarness.wait(TutorialHarness.notice(app, reading: TutorialHarness.locked))
		XCTAssertTrue(TutorialHarness.named(app, "chat.turn.tryAgain").exists)
		XCTAssertTrue(app.staticTexts[TutorialHarness.weekQuestion].exists)
		TutorialHarness.attach(self, name: "access-locked", app: app)
		TutorialHarness.assertZeroFixtureRequests(app)
	}
}

final class StopNoticeProof: XCTestCase {
	func testStopRunningAndQueuedTurns() {
		let app = XCUIApplication()
		TutorialHarness.launch(app)
		TutorialHarness.completeOnboarding(app)
		TutorialHarness.send(app, "fixture:text-then-hang")
		let partial = app.staticTexts.containing(
			NSPredicate(format: "label CONTAINS %@", "This week has Tuesday sweet spot")
		).firstMatch
		TutorialHarness.wait(partial)
		TutorialHarness.send(app, TutorialHarness.draft)
		TutorialHarness.wait(app.staticTexts[TutorialHarness.draft])
		let stop = TutorialHarness.named(app, "chat.stop")
		TutorialHarness.waitUntilHittable(stop)
		stop.tap()
		let stopped = app.staticTexts.matching(
			NSPredicate(
				format: "identifier == %@ AND label == %@", "chat.turn.notice",
				TutorialHarness.interruptedNothingChanged))
		XCTAssertTrue(
			stopped.element(boundBy: 1).waitForExistence(timeout: 8), "missing the queued notice")
		XCTAssertEqual(app.buttons.matching(identifier: "chat.turn.tryAgain").count, 2)
		XCTAssertTrue(partial.exists)
		XCTAssertFalse(app.staticTexts[TutorialHarness.receivedBeforeClose].exists)
		TutorialHarness.attach(self, name: "stop-running-and-queued", app: app)
		TutorialHarness.assertZeroFixtureRequests(app)
	}
}

final class RateLimitMinutesProof: XCTestCase {
	func testRateLimitMinutes() {
		let app = XCUIApplication()
		TutorialHarness.launch(app)
		TutorialHarness.completeOnboarding(app)
		TutorialHarness.send(app, "fixture:fail 429 90 x4")
		TutorialHarness.wait(
			TutorialHarness.notice(app, reading: TutorialHarness.rateLimitTwoMinutes),
			timeout: 330)
		let tryAgain = TutorialHarness.named(app, "chat.turn.tryAgain")
		XCTAssertTrue(tryAgain.exists)
		XCTAssertFalse(tryAgain.isEnabled, "Try again opened before the 90 second wait")
		TutorialHarness.attach(self, name: "rate-limit-minutes", app: app)
	}
}

final class RateLimitTryAgainOpensProof: XCTestCase {
	func testTryAgainOpensWhenTheWaitEnds() {
		let app = XCUIApplication()
		TutorialHarness.launch(app)
		TutorialHarness.completeOnboarding(app)
		TutorialHarness.send(app, "fixture:fail 429 6 x4")
		TutorialHarness.wait(
			TutorialHarness.notice(app, reading: TutorialHarness.rateLimitSixSeconds),
			timeout: 40)
		let shown = Date()
		let tryAgain = TutorialHarness.named(app, "chat.turn.tryAgain")
		XCTAssertFalse(tryAgain.isEnabled, "Try again opened before the wait ended")
		TutorialHarness.attach(self, name: "rate-limit-waiting", app: app)
		let enabled = XCTNSPredicateExpectation(
			predicate: NSPredicate(format: "enabled == true"), object: tryAgain)
		XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 15), .completed)
		XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(shown), 3)
		TutorialHarness.attach(self, name: "rate-limit-try-again-open", app: app)
		tryAgain.tap()
		TutorialHarness.waitForLabel(app, TutorialHarness.weekReply, timeout: 20)
		TutorialHarness.attach(self, name: "rate-limit-tried-again", app: app)
	}
}

final class FrenchFallbackProof: XCTestCase {
	func testNewNoticesFallBackToEnglish() {
		let app = XCUIApplication()
		TutorialHarness.launch(app, language: "fr", locale: "fr_FR")
		TutorialHarness.completeOnboarding(app)
		TutorialHarness.send(app, "fixture:fail 402")
		TutorialHarness.wait(TutorialHarness.notice(app, reading: TutorialHarness.creditsExhausted))
		XCTAssertEqual(
			TutorialHarness.named(app, "chat.turn.buyCredits").label, TutorialHarness.buyCredits)
		XCTAssertEqual(TutorialHarness.named(app, "chat.send").label, "Envoyer le message")
		TutorialHarness.attach(self, name: "fallback-french", app: app)
	}
}
