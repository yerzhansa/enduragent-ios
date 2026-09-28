import XCTest

final class V1TwoChatsSeedProof: XCTestCase {
	func testSeedTwoChats() {
		let app = XCUIApplication()
		TutorialHarness.launch(app)
		TutorialHarness.completeOnboarding(app)
		TutorialHarness.send(app, TutorialHarness.weekQuestion)
		TutorialHarness.waitForLabel(app, TutorialHarness.weekReply)
		app.buttons["New chat"].tap()
		TutorialHarness.waitForLabel(app, TutorialHarness.greeting)
		TutorialHarness.send(app, TutorialHarness.remember)
		TutorialHarness.waitForLabel(app, TutorialHarness.rememberReply)
		TutorialHarness.attach(self, name: "v1-two-chats", app: app)
	}
}
