import XCTest

final class FailedReplyProof: XCTestCase {
	func testFailedReply() {
		let app = XCUIApplication()
		TutorialHarness.launch(app)
		TutorialHarness.completeOnboarding(app)
		TutorialHarness.send(app, "fixture:fail 500 x3")
		let notice = TutorialHarness.named(app, "chat.turn.notice")
		TutorialHarness.wait(notice)
		XCTAssertEqual(notice.label, TutorialHarness.providerDown)
		XCTAssertTrue(TutorialHarness.named(app, "chat.turn.tryAgain").exists)
		XCTAssertFalse(TutorialHarness.named(app, "chat.error").exists)
		assertNoWireDetail(app)
		TutorialHarness.attach(self, name: "failed-reply", app: app)
		TutorialHarness.assertZeroFixtureRequests(app)
	}
}

final class FailureCopyProof: XCTestCase {
	func testFailureCopy() {
		let app = XCUIApplication()
		TutorialHarness.launch(app)
		TutorialHarness.completeOnboarding(app)
		TutorialHarness.send(app, "fixture:fail 401")
		TutorialHarness.wait(TutorialHarness.notice(app, reading: TutorialHarness.accessRejected))
		XCTAssertEqual(
			TutorialHarness.named(app, "chat.turn.restorePurchases").label,
			TutorialHarness.restorePurchases)
		XCTAssertFalse(TutorialHarness.named(app, "chat.turn.tryAgain").exists)
		TutorialHarness.attach(self, name: "failure-copy-credentials", app: app)
		TutorialHarness.send(app, "fixture:fail network x3")
		TutorialHarness.wait(TutorialHarness.notice(app, reading: TutorialHarness.providerDown))
		TutorialHarness.wait(TutorialHarness.named(app, "chat.turn.tryAgain"))
		TutorialHarness.attach(self, name: "failure-copy-network", app: app)
		TutorialHarness.send(app, "fixture:fail 429 7 x4")
		TutorialHarness.wait(
			TutorialHarness.notice(app, reading: TutorialHarness.rateLimitSevenSeconds),
			timeout: rateLimitWait)
		XCTAssertEqual(app.buttons.matching(identifier: "chat.turn.tryAgain").count, 2)
		assertNoWireDetail(app)
		TutorialHarness.attach(self, name: "failure-copy-rate-limited", app: app)
		TutorialHarness.assertZeroFixtureRequests(app)
	}
}

final class RetryLadderProof: XCTestCase {
	func testRetryLadder() {
		let app = XCUIApplication()
		TutorialHarness.launch(app)
		TutorialHarness.completeOnboarding(app)
		TutorialHarness.send(app, "fixture:fail 500")
		let sent = Date()
		let weekReply = app.staticTexts.containing(
			NSPredicate(format: "label CONTAINS %@", TutorialHarness.weekReply)
		).firstMatch
		TutorialHarness.wait(weekReply, timeout: 20)
		let reply = XCTAttachment(
			string: String(format: "send-to-reply %.2f s", Date().timeIntervalSince(sent)))
		reply.name = "retry-ladder-send-to-reply"
		reply.lifetime = .keepAlways
		add(reply)
		XCTAssertFalse(TutorialHarness.named(app, "chat.turn.notice").exists)
		TutorialHarness.attach(self, name: "retry-ladder-reply", app: app)
		TutorialHarness.send(app, "fixture:fail 429 7 x4")
		TutorialHarness.wait(TutorialHarness.named(app, "chat.working"))
		TutorialHarness.wait(
			TutorialHarness.notice(app, reading: TutorialHarness.rateLimitSevenSeconds),
			timeout: rateLimitWait)
		XCTAssertTrue(TutorialHarness.named(app, "chat.turn.tryAgain").exists)
		assertNoWireDetail(app)
		TutorialHarness.attach(self, name: "retry-ladder-rate-limited", app: app)
	}
}

private let rateLimitWait: TimeInterval = 40

private func assertNoWireDetail(_ app: XCUIApplication) {
	for raw in ["ProviderFailure", "statusCode", "URLError", "retry-after", "error\":"] {
		let match = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", raw))
		XCTAssertFalse(match.firstMatch.exists, "\(raw) is on screen")
	}
}
