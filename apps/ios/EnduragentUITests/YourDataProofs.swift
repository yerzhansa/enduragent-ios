import EnduragentCoach
import EnduragentCoachFixtures
import XCTest

@MainActor
final class YourDataProof: XCTestCase {
	func testDeleteEverythingOpensOnboardingAsAFreshInstall() {
		let app = YourDataScreen.chatWithOneReply(.erased)
		YourDataScreen.openScreen(app)
		TutorialHarness.attach(self, name: "your-data-screen-light", app: app)
		YourDataScreen.confirm(app, attaching: self)
		YourDataScreen.outcome(app, Catalog.yourDataDone)
		TutorialHarness.attach(self, name: "your-data-done-light", app: app)
		YourDataScreen.continueToOnboarding(app)
		TutorialHarness.attach(self, name: "your-data-onboarding-after-light", app: app)
		YourDataScreen.assertEmptyChatAfterOnboarding(app)
	}

	func testUnreachableCreditsServiceDeletesNothing() {
		let app = YourDataScreen.chatWithOneReply(.unreachable)
		YourDataScreen.openScreen(app)
		YourDataScreen.confirm(app)
		YourDataScreen.outcome(app, Catalog.yourDataNotStarted)
		XCTAssertEqual(
			TutorialHarness.named(app, "yourData.tryAgain").label,
			SupportScreen.say(Catalog.chatTranscriptRetry))
		TutorialHarness.attach(self, name: "your-data-not-started-light", app: app)
		TutorialHarness.named(app, "yourData.tryAgain").tap()
		YourDataScreen.outcome(app, Catalog.yourDataNotStarted)
		TutorialHarness.named(app, "yourData.cancel").tap()
		TutorialHarness.wait(TutorialHarness.named(app, "chat.composer"), until: .hittable)
		XCTAssertEqual(
			TutorialHarness.named(app, "chat.turnProgress").value as? String,
			"turns 1 settled 1")
		TutorialHarness.waitForLabel(app, TutorialHarness.weekReply)
		TutorialHarness.attach(self, name: "your-data-not-started-chat-light", app: app)
	}

	func testICloudLaterFinishesOnThisPhone() {
		let app = YourDataScreen.chatWithOneReply(.iCloudLater)
		YourDataScreen.openScreen(app)
		YourDataScreen.confirm(app)
		YourDataScreen.outcome(app, Catalog.yourDataICloudLater)
		TutorialHarness.attach(self, name: "your-data-icloud-later-light", app: app)
		YourDataScreen.continueToOnboarding(app)
	}

	func testKilledRunResumesOnTheNextLaunch() {
		let app = YourDataScreen.chatWithOneReply(.exportHeld)
		YourDataScreen.openScreen(app)
		YourDataScreen.confirm(app)
		YourDataScreen.outcome(app, Catalog.yourDataProgress)
		TutorialHarness.wait(TutorialHarness.named(app, "yourData.progress"))
		XCTAssertEqual(
			TutorialHarness.named(app, "yourData.progressTime").label,
			SupportScreen.say(Catalog.yourDataProgressTime))
		TutorialHarness.attach(self, name: "your-data-deleting-light", app: app)
		TutorialHarness.relaunchKeepingStore(app, erasure: .iCloudLater)
		YourDataScreen.outcome(app, Catalog.yourDataICloudLater)
		XCTAssertFalse(TutorialHarness.named(app, "chat.composer").exists)
		TutorialHarness.attach(self, name: "your-data-resumed-icloud-later-light", app: app)
		YourDataScreen.continueToOnboarding(app)
	}

	func testAnUnconfirmedCreditsRecordOffersToDeleteThisPhoneAndICloud() {
		let app = YourDataScreen.chatWithOneReply(.refused)
		YourDataScreen.openScreen(app)
		YourDataScreen.confirm(app)
		YourDataScreen.outcome(app, Catalog.yourDataCreditsUnconfirmed)
		XCTAssertEqual(
			TutorialHarness.named(app, "yourData.deleteHere").label,
			SupportScreen.say(Catalog.yourDataDeleteHere))
		XCTAssertTrue(TutorialHarness.named(app, "yourData.cancel").exists)
		XCTAssertFalse(TutorialHarness.named(app, "yourData.tryAgain").exists)
		TutorialHarness.attach(self, name: "your-data-credits-unconfirmed-light", app: app)
		TutorialHarness.named(app, "yourData.deleteHere").tap()
		YourDataScreen.outcome(app, Catalog.yourDataCreditsKeptDone)
		TutorialHarness.attach(self, name: "your-data-credits-kept-done-light", app: app)
		YourDataScreen.continueToOnboarding(app)
		YourDataScreen.assertEmptyChatAfterOnboarding(app)
	}

	func testAnUnconfirmedCreditsRecordWithoutICloudEndsOnTheICloudLaterSentence() {
		let app = YourDataScreen.chatWithOneReply(.refusedICloudLater)
		YourDataScreen.openScreen(app)
		YourDataScreen.confirm(app)
		YourDataScreen.outcome(app, Catalog.yourDataCreditsUnconfirmed)
		TutorialHarness.named(app, "yourData.deleteHere").tap()
		YourDataScreen.outcome(app, Catalog.yourDataCreditsKeptICloudLater)
		TutorialHarness.attach(self, name: "your-data-credits-kept-icloud-later-light", app: app)
		YourDataScreen.continueToOnboarding(app)
	}

	func testABusyCreditsServiceSaysToTryAgainLater() {
		let app = YourDataScreen.chatWithOneReply(.rateLimited)
		YourDataScreen.openScreen(app)
		YourDataScreen.confirm(app)
		YourDataScreen.outcome(app, Catalog.yourDataTryLater)
		XCTAssertTrue(TutorialHarness.named(app, "yourData.tryAgain").exists)
		TutorialHarness.attach(self, name: "your-data-try-later-light", app: app)
		TutorialHarness.named(app, "yourData.cancel").tap()
		TutorialHarness.wait(TutorialHarness.named(app, "chat.composer"), until: .hittable)
		XCTAssertEqual(
			TutorialHarness.named(app, "chat.turnProgress").value as? String,
			"turns 1 settled 1")
	}
}

@MainActor
enum YourDataScreen {
	static func chatWithOneReply(_ erasure: FixtureErasure) -> XCUIApplication {
		var arguments = FixtureArguments()
		arguments.erasure = erasure
		let app = SupportScreen.chat(arguments)
		TutorialHarness.exchange(app, TutorialHarness.weekQuestion)
		TutorialHarness.waitForLabel(app, TutorialHarness.weekReply)
		TutorialHarness.openSettings(app)
		return app
	}

	static func openScreen(_ app: XCUIApplication) {
		SupportScreen.open(app, "settings.yourData", showing: "yourData.keeps")
		XCTAssertEqual(
			TutorialHarness.named(app, "yourData.keeps").label,
			SupportScreen.say(Catalog.yourDataKeeps))
		XCTAssertEqual(
			TutorialHarness.named(app, "yourData.delete").label,
			SupportScreen.say(Catalog.yourDataDeleteEverything))
	}

	static func confirm(_ app: XCUIApplication, attaching test: XCTestCase? = nil) {
		TutorialHarness.named(app, "yourData.delete").tap()
		let alert = app.alerts.firstMatch
		TutorialHarness.wait(alert)
		XCTAssertEqual(alert.label, SupportScreen.say(Catalog.yourDataConfirmTitle))
		XCTAssertTrue(
			alert.staticTexts.matching(
				NSPredicate(format: "label == %@", SupportScreen.say(Catalog.yourDataConfirmBody))
			).firstMatch.exists)
		XCTAssertTrue(alert.buttons[SupportScreen.say(Catalog.commonCancel)].exists)
		if let test { TutorialHarness.attach(test, name: "your-data-confirm-light", app: app) }
		alert.buttons[SupportScreen.say(Catalog.yourDataDeleteEverything)].tap()
	}

	static func outcome(_ app: XCUIApplication, _ key: CatalogKey) {
		SupportScreen.outcome(app, "yourData.outcome", SupportScreen.say(key))
	}

	static func continueToOnboarding(_ app: XCUIApplication) {
		let next = TutorialHarness.named(app, "yourData.continue")
		XCTAssertEqual(next.label, SupportScreen.say(Catalog.commonContinue))
		next.tap()
		TutorialHarness.waitForLabel(app, TutorialHarness.notice)
		TutorialHarness.wait(TutorialHarness.named(app, "notice.continue"), until: .hittable)
	}

	static func assertEmptyChatAfterOnboarding(_ app: XCUIApplication) {
		TutorialHarness.startUnconnected(app)
		TutorialHarness.wait(TutorialHarness.named(app, "chat.composer"), until: .hittable)
		XCTAssertEqual(
			TutorialHarness.named(app, "chat.turnProgress").value as? String,
			"turns 0 settled 0")
		XCTAssertFalse(TutorialHarness.text(app, containing: TutorialHarness.weekReply).exists)
	}
}
