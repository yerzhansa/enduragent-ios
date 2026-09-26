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
		TutorialHarness.assertZeroFixtureRequests(app)
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
