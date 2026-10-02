import XCTest

final class RateLimitExhaustedProof: XCTestCase {
	func testRateLimitExhausted() {
		let app = XCUIApplication()
		TutorialHarness.launch(app)
		TutorialHarness.completeOnboarding(app)
		TutorialHarness.send(app, "fixture:fail 429 7 x4")
		TutorialHarness.wait(TutorialHarness.named(app, "chat.working"))
		TutorialHarness.wait(
			TutorialHarness.notice(app, reading: TutorialHarness.rateLimitSevenSeconds),
			within: .retry
		)
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
		XCTAssertFalse(
			TutorialHarness.wait(reply, within: .cooldown, required: false),
			"the reply arrived before the wait")
		XCTAssertTrue(working.exists)
		TutorialHarness.attach(self, name: "rate-limit-wait", app: app)
		TutorialHarness.wait(reply, within: .turn)
		let elapsed = Date().timeIntervalSince(sent)
		XCTAssertGreaterThanOrEqual(elapsed, 7)
		stamp(self, name: "rate-limit-wait-seconds", seconds: elapsed)
		TutorialHarness.wait(working, until: .absent)
		TutorialHarness.attach(self, name: "rate-limit-wait-reply", app: app)
		TutorialHarness.send(app, "fixture:fail 429 7 x4")
		TutorialHarness.wait(working)
		TutorialHarness.wait(
			TutorialHarness.notice(app, reading: TutorialHarness.rateLimitSevenSeconds),
			within: .retry
		)
		TutorialHarness.attach(self, name: "rate-limit-wait-exhausted", app: app)
		assertModelRequests(app, 2 + 4, test: self, name: "rate-limit-wait-requests")
	}
}

final class NetworkRetryProof: XCTestCase {
	func testNetworkRetry() {
		let app = XCUIApplication()
		TutorialHarness.launch(app)
		TutorialHarness.completeOnboarding(app)
		TutorialHarness.exchange(app, "fixture:fail network x2")
		TutorialHarness.wait(weekReply(app), within: .turn)
		XCTAssertFalse(TutorialHarness.named(app, "chat.turn.notice").exists)
		TutorialHarness.attach(self, name: "network-retry", app: app)
		TutorialHarness.exchange(app, "fixture:fail network x3")
		TutorialHarness.wait(
			TutorialHarness.notice(app, reading: TutorialHarness.providerDown), within: .turn)
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
		TutorialHarness.exchange(app, "fixture:fail overflow x4")
		TutorialHarness.wait(
			TutorialHarness.notice(app, reading: TutorialHarness.unknownFailure), within: .turn)
		XCTAssertTrue(TutorialHarness.named(app, "chat.turn.tryAgain").exists)
		TutorialHarness.attach(self, name: "overflow-exhausted", app: app)
		TutorialHarness.openRecords(app)
		TutorialHarness.waitForRecordCount(app, "turnSettled", "turnSettled 1")
		XCTAssertNil(TutorialHarness.recordCount(app, "compactionSummary"))
		XCTAssertNil(TutorialHarness.recordCount(app, "windowStart"))
		TutorialHarness.attach(self, name: "overflow-exhausted-records", app: app)
		TutorialHarness.returnToChat(app)
		assertModelRequests(app, 4 + 1, test: self, name: "overflow-requests")
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
		TutorialHarness.returnToChat(app)
		TutorialHarness.wait(
			TutorialHarness.notice(app, reading: TutorialHarness.providerDown), within: .retry)
		TutorialHarness.attach(self, name: "observed-text-timeout", app: app)
		assertModelRequests(app, 1, test: self, name: "observed-text-requests")
	}
}

final class NoCrossChatMemoProof: XCTestCase {
	func testNoCrossChatMemo() {
		let app = XCUIApplication()
		TutorialHarness.launch(app)
		TutorialHarness.completeOnboarding(app)
		TutorialHarness.exchange(app, TutorialHarness.workout)
		let add = TutorialHarness.named(app, "chat.preview.add")
		TutorialHarness.wait(add)
		add.tap()
		TutorialHarness.wait(containing(app, TutorialHarness.done))
		TutorialHarness.attach(self, name: "no-cross-chat-memo-done", app: app)
		TutorialHarness.exchange(app, "fixture:fail 500")
		TutorialHarness.wait(weekReply(app), within: .turn)
		XCTAssertTrue(containing(app, "I've prepared the ride.").exists)
		XCTAssertFalse(TutorialHarness.named(app, "chat.turn.notice").exists)
		TutorialHarness.attach(self, name: "no-cross-chat-memo", app: app)
		TutorialHarness.assertZeroFixtureRequests(app)
	}
}

private func weekReply(_ app: XCUIApplication) -> XCUIElement {
	containing(app, TutorialHarness.weekReply)
}

private func containing(_ app: XCUIApplication, _ text: String) -> XCUIElement {
	app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
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
	TutorialHarness.wait(TutorialHarness.named(app, "chat.working"), until: .absent)
	TutorialHarness.openDebug(app)
	let count = TutorialHarness.debugRow(app, "fixture.requestCount")
	XCTAssertEqual(count.label, "0 requests")
	let model = TutorialHarness.debugRow(app, "fixture.modelRequestCount")
	XCTAssertEqual(model.label, "\(expected) model requests")
	TutorialHarness.attach(test, name: name, app: app)
	TutorialHarness.returnToChat(app)
}
