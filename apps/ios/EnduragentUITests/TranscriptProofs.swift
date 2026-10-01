import XCTest

final class LongRepliesProof: XCTestCase {
	func testLongReplies() {
		let app = XCUIApplication()
		TutorialHarness.launch(app)
		TutorialHarness.completeOnboarding(app)
		for _ in 1...3 {
			TutorialHarness.sendLong(app)
		}
		TutorialHarness.exchange(app, TutorialHarness.weekQuestion)
		TutorialHarness.waitForLabel(app, TutorialHarness.weekReply)
		TutorialHarness.attach(self, name: "long-replies", app: app)
		TutorialHarness.openRecords(app)
		TutorialHarness.waitForRecordCount(app, "turnSettled", "turnSettled 4")
		TutorialHarness.returnToChat(app)
		TutorialHarness.assertZeroFixtureRequests(app)
	}
}
