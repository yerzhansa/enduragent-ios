import XCTest

final class FailureCopyProof: XCTestCase {
	func testFailureCopy() {
		let app = XCUIApplication()
		TutorialHarness.launch(app)
		TutorialHarness.completeOnboarding(app)
		TutorialHarness.send(app, "fixture:fail 401")
		TutorialHarness.wait(notice(app, reading: TutorialHarness.providerCredentials))
		XCTAssertFalse(TutorialHarness.named(app, "chat.turn.tryAgain").exists)
		TutorialHarness.attach(self, name: "failure-copy-credentials", app: app)
		TutorialHarness.send(app, "fixture:fail network")
		TutorialHarness.wait(notice(app, reading: TutorialHarness.providerDown))
		TutorialHarness.wait(TutorialHarness.named(app, "chat.turn.tryAgain"))
		TutorialHarness.attach(self, name: "failure-copy-network", app: app)
		TutorialHarness.send(app, "fixture:fail 429 7")
		TutorialHarness.wait(notice(app, reading: TutorialHarness.rateLimitSevenSeconds))
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

final class FailurePlaceholderProof: XCTestCase {
	func testFailurePlaceholders() {
		let app = XCUIApplication()
		TutorialHarness.launch(app)
		TutorialHarness.completeOnboarding(app)
		TutorialHarness.send(app, "fixture:fail timeout")
		TutorialHarness.wait(notice(app, reading: TutorialHarness.providerDown))
		XCTAssertEqual(app.buttons.matching(identifier: "chat.turn.tryAgain").count, 1)
		TutorialHarness.attach(self, name: "failure-timeout", app: app)
		TutorialHarness.send(app, "fixture:fail 402")
		TutorialHarness.wait(notice(app, reading: TutorialHarness.unknownFailure))
		XCTAssertEqual(app.buttons.matching(identifier: "chat.turn.tryAgain").count, 1)
		TutorialHarness.attach(self, name: "failure-exhausted", app: app)
		TutorialHarness.send(app, "fixture:fail overflow")
		let notices = app.staticTexts.matching(
			NSPredicate(
				format: "identifier == %@ AND label == %@", "chat.turn.notice",
				TutorialHarness.unknownFailure))
		XCTAssertTrue(
			notices.element(boundBy: 1).waitForExistence(timeout: 8), "missing overflow notice")
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
		TutorialHarness.send(app, "fixture:fail network")
		TutorialHarness.wait(notice(app, reading: TutorialHarness.providerDown))
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
		composer.typeText("fixture:fail 500")
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

private func notice(_ app: XCUIApplication, reading sentence: String) -> XCUIElement {
	app.staticTexts.matching(
		NSPredicate(format: "identifier == %@ AND label == %@", "chat.turn.notice", sentence)
	).firstMatch
}

func assertNoWireDetail(_ app: XCUIApplication) {
	for raw in ["ProviderFailure", "statusCode", "URLError", "retry-after", "error\":"] {
		let match = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", raw))
		XCTAssertFalse(match.firstMatch.exists, "\(raw) is on screen")
	}
}
