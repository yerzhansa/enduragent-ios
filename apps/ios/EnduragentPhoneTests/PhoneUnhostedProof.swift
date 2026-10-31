import XCTest

final class PhoneUnhostedProof: XCTestCase {
	static let installed = "icu.enduragent.app"

	func testWritesAConversationInTheInstalledApp() {
		let app = XCUIApplication(bundleIdentifier: Self.installed)
		TutorialHarness.launch(app, arguments: FixtureArguments())
		TutorialHarness.completeOnboarding(app)
		TutorialHarness.exchange(app, TutorialHarness.weekQuestion)
		TutorialHarness.waitForLabel(app, TutorialHarness.weekReply)
		TutorialHarness.attach(self, name: "unhosted-written", app: app)
	}

	func testShowsTheConversationWrittenBeforeTheRun() {
		let app = XCUIApplication(bundleIdentifier: Self.installed)
		TutorialHarness.launch(app, arguments: FixtureArguments(store: .keep))
		TutorialHarness.wait(TutorialHarness.named(app, "chat.composer"))
		TutorialHarness.waitForLabel(app, TutorialHarness.weekQuestion)
		TutorialHarness.waitForLabel(app, TutorialHarness.weekReply)
		TutorialHarness.attach(self, name: "unhosted-kept", app: app)
		TutorialHarness.exchange(app, TutorialHarness.remember)
		TutorialHarness.waitForLabel(app, TutorialHarness.rememberReply)
		TutorialHarness.attach(self, name: "unhosted-replied", app: app)
	}
}
