import XCTest

final class RateLimitExhaustedProof: XCTestCase {
	func testRateLimitExhausted() {
		let app = XCUIApplication()
		TutorialHarness.launch(app)
		TutorialHarness.completeOnboarding(app)
		TutorialHarness.send(app, "fixture:fail 429 7 x4")
		TutorialHarness.wait(TutorialHarness.named(app, "chat.working"))
		TutorialHarness.wait(
			turnNotice(app, reading: TutorialHarness.rateLimitSevenSeconds), timeout: 40)
		XCTAssertTrue(TutorialHarness.named(app, "chat.turn.tryAgain").exists)
		TutorialHarness.attach(self, name: "rate-limit-exhausted", app: app)
		assertModelRequests(app, 4, test: self, name: "rate-limit-exhausted-requests")
	}
}

final class RateLimitWaitProof: XCTestCase {
	func testRateLimitWait() {
		let app = XCUIApplication()
		TutorialHarness.launch(app)
		TutorialHarness.completeOnboarding(app)
		TutorialHarness.send(app, "fixture:fail 429 7")
		let sent = Date()
		let working = TutorialHarness.named(app, "chat.working")
		TutorialHarness.wait(working)
		let reply = weekReply(app)
		XCTAssertFalse(reply.waitForExistence(timeout: 5), "the reply arrived before the wait")
		XCTAssertTrue(working.exists)
		TutorialHarness.attach(self, name: "rate-limit-wait", app: app)
		TutorialHarness.wait(reply, timeout: 15)
		let elapsed = Date().timeIntervalSince(sent)
		XCTAssertGreaterThanOrEqual(elapsed, 7)
		stamp(self, name: "rate-limit-wait-seconds", seconds: elapsed)
		waitUntilGone(working)
		TutorialHarness.attach(self, name: "rate-limit-wait-reply", app: app)
		TutorialHarness.send(app, "fixture:fail 429 7 x4")
		TutorialHarness.wait(working)
		TutorialHarness.wait(
			turnNotice(app, reading: TutorialHarness.rateLimitSevenSeconds), timeout: 40)
		TutorialHarness.attach(self, name: "rate-limit-wait-exhausted", app: app)
		assertModelRequests(app, 2 + 4, test: self, name: "rate-limit-wait-requests")
	}
}

final class NetworkRetryProof: XCTestCase {
	func testNetworkRetry() {
		let app = XCUIApplication()
		TutorialHarness.launch(app)
		TutorialHarness.completeOnboarding(app)
		TutorialHarness.send(app, "fixture:fail network x2")
		TutorialHarness.wait(weekReply(app), timeout: 20)
		XCTAssertFalse(TutorialHarness.named(app, "chat.turn.notice").exists)
		TutorialHarness.attach(self, name: "network-retry", app: app)
		TutorialHarness.send(app, "fixture:fail network x3")
		TutorialHarness.wait(turnNotice(app, reading: TutorialHarness.providerDown), timeout: 20)
		XCTAssertTrue(TutorialHarness.named(app, "chat.turn.tryAgain").exists)
		TutorialHarness.attach(self, name: "network-exhausted", app: app)
		assertModelRequests(app, 6, test: self, name: "network-requests")
	}
}

final class OverflowExhaustedProof: XCTestCase {
	func testOverflowExhausted() {
		let app = XCUIApplication()
		TutorialHarness.launch(app)
		TutorialHarness.completeOnboarding(app)
		TutorialHarness.send(app, "fixture:fail overflow x4")
		TutorialHarness.wait(turnNotice(app, reading: TutorialHarness.unknownFailure), timeout: 20)
		XCTAssertTrue(TutorialHarness.named(app, "chat.turn.tryAgain").exists)
		TutorialHarness.attach(self, name: "overflow-exhausted", app: app)
		TutorialHarness.openRecords(app)
		TutorialHarness.waitForRecordCount(app, "compactionSummary", "compactionSummary 3")
		TutorialHarness.attach(self, name: "overflow-exhausted-records", app: app)
		TutorialHarness.closeMenu(app)
		assertModelRequests(app, 4 + 3, test: self, name: "overflow-requests")
	}
}

final class ReplyObservedProof: XCTestCase {
	func testReplyObserved() {
		let app = XCUIApplication()
		TutorialHarness.launch(app)
		TutorialHarness.completeOnboarding(app)
		TutorialHarness.send(app, "fixture:text-then-hang")
		TutorialHarness.wait(containing(app, "This week has Tuesday sweet spot"))
		XCTAssertTrue(TutorialHarness.named(app, "chat.working").exists)
		TutorialHarness.attach(self, name: "observed-text", app: app)
		TutorialHarness.openRecords(app)
		TutorialHarness.waitForRecordCount(app, "replyObserved", "replyObserved 1")
		XCTAssertNil(TutorialHarness.recordCount(app, "turnSettled"), "the reply already settled")
		TutorialHarness.attach(self, name: "observed-text-records", app: app)
		TutorialHarness.closeMenu(app)
		TutorialHarness.wait(turnNotice(app, reading: TutorialHarness.providerDown), timeout: 40)
		TutorialHarness.attach(self, name: "observed-text-timeout", app: app)
		assertModelRequests(app, 1, test: self, name: "observed-text-requests")
	}
}

final class NoCrossChatMemoProof: XCTestCase {
	func testNoCrossChatMemo() {
		let app = XCUIApplication()
		TutorialHarness.launch(app)
		TutorialHarness.completeOnboarding(app)
		TutorialHarness.send(app, TutorialHarness.workout)
		let add = TutorialHarness.named(app, "chat.preview.add")
		TutorialHarness.wait(add)
		add.tap()
		TutorialHarness.wait(containing(app, TutorialHarness.done))
		TutorialHarness.attach(self, name: "no-cross-chat-memo-done", app: app)
		TutorialHarness.send(app, "fixture:fail 500")
		TutorialHarness.wait(weekReply(app), timeout: 20)
		XCTAssertTrue(containing(app, "I've prepared the ride.").exists)
		XCTAssertFalse(TutorialHarness.named(app, "chat.turn.notice").exists)
		TutorialHarness.attach(self, name: "no-cross-chat-memo", app: app)
		TutorialHarness.assertZeroFixtureRequests(app)
	}
}

private func turnNotice(_ app: XCUIApplication, reading sentence: String) -> XCUIElement {
	app.staticTexts.matching(
		NSPredicate(format: "identifier == %@ AND label == %@", "chat.turn.notice", sentence)
	).firstMatch
}

private func weekReply(_ app: XCUIApplication) -> XCUIElement {
	containing(app, TutorialHarness.weekReply)
}

private func containing(_ app: XCUIApplication, _ text: String) -> XCUIElement {
	app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
}

private func waitUntilGone(_ element: XCUIElement) {
	let gone = XCTNSPredicateExpectation(
		predicate: NSPredicate(format: "exists == false"), object: element)
	XCTAssertEqual(
		XCTWaiter.wait(for: [gone], timeout: 10), .completed, "still on screen \(element)")
}

private func stamp(_ test: XCTestCase, name: String, seconds: TimeInterval) {
	let sample = XCTAttachment(string: String(format: "%.2f s", seconds))
	sample.name = name
	sample.lifetime = .keepAlways
	test.add(sample)
}

private func assertModelRequests(
	_ app: XCUIApplication, _ expected: Int, test: XCTestCase, name: String
) {
	waitUntilGone(TutorialHarness.named(app, "chat.working"))
	TutorialHarness.openSidebar(app)
	TutorialHarness.named(app, "sidebar.debug").tap()
	let model = TutorialHarness.named(app, "fixture.modelRequestCount")
	TutorialHarness.wait(model)
	XCTAssertEqual(model.label, "\(expected) model requests")
	XCTAssertEqual(TutorialHarness.named(app, "fixture.requestCount").label, "0 requests")
	TutorialHarness.attach(test, name: name, app: app)
	TutorialHarness.closeMenu(app)
}
