import XCTest

final class ProviderConsentProof: XCTestCase {
	func testDecliningKeepsChatClosedAndRelaunchAsksAgain() {
		let app = XCUIApplication()
		TutorialHarness.launch(app)
		TutorialHarness.wait(TutorialHarness.named(app, "notice.continue"))
		TutorialHarness.named(app, "notice.continue").tap()
		TutorialHarness.wait(TutorialHarness.named(app, "connect.skip"))
		TutorialHarness.named(app, "connect.skip").tap()
		TutorialHarness.wait(TutorialHarness.named(app, "starter.start"))
		TutorialHarness.named(app, "starter.start").tap()
		let decline = TutorialHarness.named(app, "consent.decline")
		TutorialHarness.wait(decline)
		XCTAssertFalse(TutorialHarness.named(app, "chat.composer").exists)
		TutorialHarness.attach(self, name: "provider-consent", app: app)
		decline.tap()
		TutorialHarness.wait(TutorialHarness.named(app, "starter.start"))
		XCTAssertFalse(TutorialHarness.named(app, "chat.composer").exists)
		TutorialHarness.named(app, "starter.start").tap()
		TutorialHarness.wait(decline)
		decline.tap()
		TutorialHarness.relaunchKeepingStore(app)
		TutorialHarness.agreeToProviderConsent(app)
		TutorialHarness.send(app, TutorialHarness.weekQuestion)
		TutorialHarness.waitForLabel(app, TutorialHarness.weekReply)
		TutorialHarness.openRecords(app)
		TutorialHarness.waitForRecordCount(app, "providerConsent", "providerConsent 1")
		TutorialHarness.closeMenu(app)
		TutorialHarness.assertZeroFixtureRequests(app)
	}
}
