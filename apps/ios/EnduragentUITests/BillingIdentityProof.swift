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
		let buyCredits = TutorialHarness.named(app, "chat.turn.buyCredits")
		let switchFromNotice = TutorialHarness.named(app, "chat.turn.switchToOpenRouter")
		assertNoticeActions(app, buy: "Buy Credits", switchAccess: "Switch to OpenRouter")
		capture(app, "exhausted-conversation")
		switchFromNotice.tap()
		TutorialHarness.wait(app.navigationBars[phrasebook.say(Catalog.accessTitle)])
		assertChoice(app, credits: true)
		capture(app, "notice-switch-keeps-credits")
		TutorialHarness.returnToChat(app, maximumBackSteps: 1)
		TutorialHarness.wait(TutorialHarness.notice(app, reading: sentence))
		TutorialHarness.waitForLabel(
			app, "Noted. I'll remember you ride with a group on Saturdays.")
		assertNoticeActions(app, buy: "Buy Credits", switchAccess: "Switch to OpenRouter")
		capture(app, "back-from-notice-switch")
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
		assertNoticeActions(app, buy: "Buy Credits", switchAccess: "Switch to OpenRouter")
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
	}

	func testRejectedOpenRouterKeepsItsChoiceThroughRecoveryAndLaterTurns() {
		let app = XCUIApplication()
		TutorialHarness.launch(app, arguments: FixtureArguments(accessMethod: .openRouter))
		TutorialHarness.completeOnboarding(app)
		TutorialHarness.exchange(app, "fixture:fail 401")
		let sentence = phrasebook.say(Catalog.coachErrorReauth, ["provider": "OpenRouter"])
		TutorialHarness.waitForIdentifier(app, "chat.access.notice", reading: sentence)
		capture(app, "openrouter-rejected")
		let signIn = TutorialHarness.named(app, "chat.access.signInAgain")
		TutorialHarness.wait(signIn, until: .hittable)
		XCTAssertEqual(signIn.label, "Sign in again")
		signIn.tap()
		TutorialHarness.waitForIdentifier(
			app, "chat.access.outcome", reading: phrasebook.say(Catalog.accessSignInCancelled))
		TutorialHarness.wait(signIn, until: .enabled)
		TutorialHarness.waitForIdentifier(app, "chat.access.notice", reading: sentence)
		capture(app, "sign-in-again-cancelled")
		openAccess(app)
		assertChoice(app, credits: false)
		XCTAssertFalse(TutorialHarness.named(app, "connect.apiKey").exists)
		TutorialHarness.returnToChat(app)
		TutorialHarness.exchange(app, "fixture:fail 401")
		TutorialHarness.relaunchKeepingStore(app)
		TutorialHarness.wait(TutorialHarness.named(app, "chat.composer"))
		TutorialHarness.waitForIdentifier(app, "chat.access.notice", reading: sentence)
		openAccess(app)
		assertChoice(app, credits: false)
		capture(app, "reopened-openrouter-choice")
		TutorialHarness.returnToChat(app)
	}

	func testOutOfCreditsActionsFitInTheLongestTranslations() {
		for (language, locale, tag) in [("fr", "fr_FR", LanguageTag.fr), ("nl", "nl_NL", .nl)] {
			let app = XCUIApplication()
			let translated = CatalogPhrasebook(tag: tag)
			TutorialHarness.launch(app, language: language, locale: locale)
			TutorialHarness.completeOnboarding(app, language: tag)
			TutorialHarness.exchange(app, "fixture:fail 402")
			TutorialHarness.wait(
				TutorialHarness.notice(app, reading: translated.say(Catalog.creditsErrorExhausted)))
			assertNoticeActions(
				app, buy: translated.say(Catalog.chatTurnBuyCredits),
				switchAccess: translated.say(Catalog.accessSwitchToOpenRouter))
			capture(app, "exhausted-conversation-\(language)")
			app.terminate()
		}
	}

	private var phrasebook: CatalogPhrasebook { CatalogPhrasebook(tag: .en) }

	private func assertNoticeActions(_ app: XCUIApplication, buy: String, switchAccess: String) {
		let buyCredits = TutorialHarness.named(app, "chat.turn.buyCredits")
		let switchFromNotice = TutorialHarness.named(app, "chat.turn.switchToOpenRouter")
		TutorialHarness.wait(buyCredits, until: .hittable)
		TutorialHarness.wait(switchFromNotice, until: .hittable)
		XCTAssertEqual(buyCredits.label, buy)
		XCTAssertEqual(switchFromNotice.label, switchAccess)
		XCTAssertLessThanOrEqual(buyCredits.frame.maxY, switchFromNotice.frame.minY)
		let screen = app.windows.firstMatch.frame
		XCTAssertTrue(screen.contains(buyCredits.frame))
		XCTAssertTrue(screen.contains(switchFromNotice.frame))
		XCTAssertEqual(app.buttons.matching(identifier: "chat.turn.buyCredits").count, 1)
		XCTAssertEqual(app.buttons.matching(identifier: "chat.turn.switchToOpenRouter").count, 1)
	}

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
		TutorialHarness.attach(self, name: "billing-identity-\(result)", app: app)
	}
}
