import XCTest

final class V1PendingReviewSeedProof: XCTestCase {
	func testSeedPendingReviewInTheMainChat() {
		let app = XCUIApplication()
		app.launchArguments = [
			"-EnduragentFixture", "first-week", TutorialHarness.storeArgument, "fresh",
			"-AppleLanguages", "(en)", "-AppleLocale", "en_US",
			"-enduragent.onboardingCompleted", "YES",
		]
		app.launch()
		TutorialHarness.send(app, TutorialHarness.workout)
		TutorialHarness.wait(TutorialHarness.named(app, "chat.preview.add"))
		TutorialHarness.waitForLabel(app, TutorialHarness.warmup)
		TutorialHarness.attach(self, name: "v1-pending-review", app: app)
	}
}
