import XCTest

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
		TutorialHarness.openSidebar(app)
		TutorialHarness.named(app, "sidebar.debug").tap()
		let count = TutorialHarness.named(app, "fixture.requestCount")
		TutorialHarness.wait(count)
		XCTAssertEqual(count.label, "0 requests")
		TutorialHarness.attach(self, name: "failure-copy-request-count", app: app)
		TutorialHarness.closeMenu(app)
	}
}

final class FailureNoticesProof: XCTestCase {
	func testFailureNotices() {
		let app = XCUIApplication()
		TutorialHarness.launch(app)
		TutorialHarness.completeOnboarding(app)
		TutorialHarness.send(app, "fixture:fail timeout x2")
		TutorialHarness.wait(TutorialHarness.notice(app, reading: TutorialHarness.providerDown))
		XCTAssertEqual(app.buttons.matching(identifier: "chat.turn.tryAgain").count, 1)
		TutorialHarness.attach(self, name: "failure-timeout", app: app)
		TutorialHarness.send(app, "fixture:fail 402")
		TutorialHarness.wait(TutorialHarness.notice(app, reading: TutorialHarness.creditsExhausted))
		XCTAssertTrue(TutorialHarness.named(app, "chat.turn.buyCredits").exists)
		XCTAssertEqual(app.buttons.matching(identifier: "chat.turn.tryAgain").count, 1)
		TutorialHarness.attach(self, name: "failure-exhausted", app: app)
		TutorialHarness.send(app, "fixture:fail overflow x4")
		TutorialHarness.wait(TutorialHarness.notice(app, reading: TutorialHarness.unknownFailure))
		XCTAssertEqual(app.buttons.matching(identifier: "chat.turn.tryAgain").count, 2)
		XCTAssertFalse(
			app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "131072"))
				.firstMatch.exists)
		assertNoWireDetail(app)
		TutorialHarness.attach(self, name: "failure-overflow", app: app)
		TutorialHarness.assertZeroFixtureRequests(app)
	}
}

final class FailedNetworkDarkProof: XCTestCase {
	func testFailedNetworkDark() {
		let app = XCUIApplication()
		TutorialHarness.launch(app, dark: true)
		TutorialHarness.completeOnboarding(app)
		TutorialHarness.send(app, "fixture:fail network x3")
		TutorialHarness.wait(TutorialHarness.notice(app, reading: TutorialHarness.providerDown))
		TutorialHarness.wait(TutorialHarness.named(app, "chat.turn.tryAgain"))
		TutorialHarness.attach(self, name: "failed-network-dark", app: app)
		TutorialHarness.assertZeroFixtureRequests(app)
	}
}

final class FailNoticeLatencyProbe: XCTestCase {
	func testFailNoticeLatency() {
		let app = XCUIApplication()
		TutorialHarness.launch(app)
		TutorialHarness.completeOnboarding(app)
		let composer = TutorialHarness.named(app, "chat.composer")
		composer.tap()
		composer.typeText("fixture:fail 500 x3")
		let send = TutorialHarness.named(app, "chat.send")
		TutorialHarness.wait(send)
		let failure = TutorialHarness.named(app, "chat.turn.notice")
		let tapped = Date()
		send.tap()
		while !failure.exists, Date().timeIntervalSince(tapped) < 15 {
			continue
		}
		let latency = Date().timeIntervalSince(tapped)
		XCTAssertTrue(failure.exists)
		let sample = XCTAttachment(string: String(format: "%.0f", latency * 1_000))
		sample.name = "fail-notice-latency-ms"
		sample.lifetime = .keepAlways
		add(sample)
		TutorialHarness.attach(self, name: "fail-notice", app: app)
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
		TutorialHarness.assertZeroFixtureRequests(app)
	}
}

final class SavedUnverifiedProof: XCTestCase {
	func testSavedWorkOffersNoTryAgain() {
		let app = XCUIApplication()
		TutorialHarness.launch(app)
		TutorialHarness.completeOnboarding(app)
		TutorialHarness.send(app, "fixture:memory-then-fail")
		TutorialHarness.wait(TutorialHarness.notice(app, reading: TutorialHarness.savedUnverified))
		XCTAssertFalse(TutorialHarness.named(app, "chat.turn.tryAgain").exists)
		assertNoWireDetail(app)
		TutorialHarness.attach(self, name: "saved-unverified", app: app)
		TutorialHarness.openRecords(app)
		TutorialHarness.waitForRecordCount(app, "memorySection", "memorySection 1")
		TutorialHarness.attach(self, name: "saved-unverified-records", app: app)
		TutorialHarness.closeMenu(app)
		TutorialHarness.send(app, "fixture:memory-then-hang")
		TutorialHarness.wait(TutorialHarness.named(app, "chat.working"))
		TutorialHarness.openRecords(app)
		TutorialHarness.waitForRecordCount(app, "memorySection", "memorySection 2")
		TutorialHarness.closeMenu(app)
		let stop = TutorialHarness.named(app, "chat.stop")
		TutorialHarness.waitUntilHittable(stop)
		stop.tap()
		TutorialHarness.wait(
			TutorialHarness.notice(app, reading: TutorialHarness.interruptedSomeSaved))
		XCTAssertFalse(TutorialHarness.named(app, "chat.turn.tryAgain").exists)
		TutorialHarness.attach(self, name: "stopped-after-save", app: app)
		TutorialHarness.assertZeroFixtureRequests(app)
	}
}

private let rateLimitWait: TimeInterval = 40

func assertNoWireDetail(_ app: XCUIApplication) {
	for raw in ["ProviderFailure", "statusCode", "URLError", "retry-after", "error\":"] {
		let match = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", raw))
		XCTAssertFalse(match.firstMatch.exists, "\(raw) is on screen")
	}
}
