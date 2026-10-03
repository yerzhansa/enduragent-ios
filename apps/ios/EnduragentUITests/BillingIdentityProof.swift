import EnduragentCoach
import XCTest

@MainActor
final class BillingIdentityProof: XCTestCase {
	func testExhaustedCreditsKeepMemoryAndMessagesAndOfferWorkingRoutes() {
		let app = XCUIApplication()
		TutorialHarness.launch(app, arguments: FixtureArguments(accessMethod: .credits))
		TutorialHarness.completeOnboarding(app)
		TutorialHarness.exchange(app, "fixture:teach")
		TutorialHarness.waitForLabel(
			app, "Noted. I'll remember you ride with a group on Saturdays.")
		TutorialHarness.exchange(app, "fixture:fail 402")
		let sentence = "You're out of Credits. You can switch to your OpenRouter account."
		TutorialHarness.wait(TutorialHarness.notice(app, reading: sentence))
		capture(app, "exhausted-conversation")
		let buyCredits = TutorialHarness.named(app, "chat.turn.buyCredits")
		TutorialHarness.wait(buyCredits, until: .hittable)
		XCTAssertEqual(buyCredits.label, "Buy Credits")
		buyCredits.tap()
		TutorialHarness.waitForIdentifier(app, "credits.balance", reading: "0 credits")
		TutorialHarness.waitForIdentifier(app, "credits.notice", reading: sentence)
		XCTAssertEqual(
			TutorialHarness.named(app, "credits.note").label, "Testers cannot buy packs yet.")
		let buy = app.buttons.matching(
			NSPredicate(format: "label == %@", phrasebook.say(Catalog.creditsBuy)))
		XCTAssertEqual(buy.count, 2)
		for button in buy.allElementsBoundByIndex { XCTAssertFalse(button.isEnabled) }
		capture(app, "zero-credits-buy-disabled")
		let switchAccess = TutorialHarness.named(app, "credits.switchToOpenRouter")
		TutorialHarness.wait(switchAccess, until: .hittable)
		XCTAssertEqual(switchAccess.label, "Switch to OpenRouter")
		switchAccess.tap()
		assertChoice(app, credits: true)
		capture(app, "switch-destination-keeps-credits")
		TutorialHarness.returnToChat(app)
		TutorialHarness.relaunchKeepingStore(app)
		TutorialHarness.wait(TutorialHarness.named(app, "chat.composer"))
		TutorialHarness.wait(TutorialHarness.notice(app, reading: sentence))
		TutorialHarness.waitForLabel(
			app, "Noted. I'll remember you ride with a group on Saturdays.")
		capture(app, "reopened-conversation")
		openAccess(app)
		assertChoice(app, credits: true)
		TutorialHarness.returnToChat(app)
		TutorialHarness.openRecords(app)
		TutorialHarness.waitForRecordCount(app, "memorySection", "memorySection 1")
		XCTAssertEqual(TutorialHarness.recordCount(app, "userMessage"), "userMessage 2")
		XCTAssertEqual(TutorialHarness.recordCount(app, "turnSettled"), "turnSettled 2")
		capture(app, "reopened-saved-memory-and-messages")
		TutorialHarness.returnToChat(app)
		TutorialHarness.assertZeroFixtureRequests(app)
	}

	func testRejectedOpenRouterKeepsItsChoiceThroughRecoveryAndLaterTurns() {
		let app = XCUIApplication()
		TutorialHarness.launch(app, arguments: FixtureArguments(accessMethod: .openRouter))
		TutorialHarness.completeOnboarding(app)
		TutorialHarness.exchange(app, "fixture:fail 401")
		let sentence = phrasebook.say(Catalog.coachErrorReauth, ["provider": "OpenRouter"])
		TutorialHarness.wait(TutorialHarness.notice(app, reading: sentence))
		capture(app, "openrouter-rejected")
		let signIn = TutorialHarness.named(app, "chat.turn.signInAgain")
		TutorialHarness.wait(signIn, until: .hittable)
		XCTAssertEqual(signIn.label, "Sign in again")
		signIn.tap()
		assertChoice(app, credits: false)
		XCTAssertFalse(TutorialHarness.named(app, "connect.apiKey").exists)
		capture(app, "sign-in-destination-keeps-openrouter")
		TutorialHarness.returnToChat(app)
		TutorialHarness.exchange(app, "fixture:fail 401")
		TutorialHarness.relaunchKeepingStore(app)
		TutorialHarness.wait(TutorialHarness.named(app, "chat.composer"))
		TutorialHarness.wait(TutorialHarness.notice(app, reading: sentence))
		openAccess(app)
		assertChoice(app, credits: false)
		capture(app, "reopened-openrouter-choice")
		TutorialHarness.returnToChat(app)
		TutorialHarness.assertZeroFixtureRequests(app)
	}

	private var phrasebook: CatalogPhrasebook { CatalogPhrasebook(tag: .en) }

	private func assertChoice(_ app: XCUIApplication, credits: Bool) {
		let creditsChoice = TutorialHarness.named(app, "access.credits")
		let openRouter = TutorialHarness.named(app, "access.openRouter")
		TutorialHarness.wait(creditsChoice, until: .hittable)
		TutorialHarness.wait(openRouter, until: .hittable)
		XCTAssertEqual(creditsChoice.isSelected, credits)
		XCTAssertEqual(openRouter.isSelected, !credits)
	}

	private func openAccess(_ app: XCUIApplication) {
		TutorialHarness.openSettings(app)
		let access = TutorialHarness.named(app, "settings.accessMethod")
		TutorialHarness.wait(access, until: .hittable)
		access.tap()
		TutorialHarness.wait(app.navigationBars[phrasebook.say(Catalog.accessTitle)])
	}

	private func capture(_ app: XCUIApplication, _ result: String) {
		let appearance = TutorialHarness.meanLuminance(app.screenshot()) < 0.4 ? "dark" : "light"
		TutorialHarness.attach(self, name: "billing-identity-\(result)-\(appearance)", app: app)
	}
}
