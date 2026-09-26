import XCTest

final class LongRepliesProof: XCTestCase {
	func testLongReplies() {
		let app = XCUIApplication()
		TutorialHarness.launch(app)
		TutorialHarness.completeOnboarding(app)
		for count in 1...3 {
			TutorialHarness.sendLong(app, expectingReplies: count)
		}
		TutorialHarness.send(app, TutorialHarness.weekQuestion)
		TutorialHarness.waitForLabel(app, TutorialHarness.weekReply)
		XCTAssertTrue(TutorialHarness.named(app, "chat.working").waitForNonExistence(timeout: 30))
		TutorialHarness.attach(self, name: "long-replies", app: app)
		TutorialHarness.assertZeroFixtureRequests(app)
	}
}
