import EnduragentCoach
import XCTest

@MainActor
final class BillingIdentityProof: XCTestCase {
	func testExhaustedCreditsKeepMemoryAndMessagesAndOfferBuyCredits() {
		let app = XCUIApplication()
		TutorialHarness.launch(app, arguments: FixtureArguments(accessMethod: .credits))
		TutorialHarness.completeOnboarding(app)
		TutorialHarness.exchange(app, "fixture:teach")
		TutorialHarness.waitForLabel(
			app, "Noted. I'll remember you ride with a group on Saturdays.")
		TutorialHarness.exchange(app, "fixture:fail 402")
		let sentence = "You're out of Credits. You can buy Credits."
		TutorialHarness.wait(TutorialHarness.notice(app, reading: sentence))
		assertNoticeAction(app, buy: "Buy Credits")
		capture(app, "exhausted-conversation")
		TutorialHarness.named(app, "chat.turn.buyCredits").tap()
		TutorialHarness.waitForIdentifier(app, "credits.balance", reading: "0 credits")
		TutorialHarness.waitForIdentifier(app, "credits.notice", reading: sentence)
		TutorialHarness.waitForIdentifier(
			app, "credits.pack.icu.enduragent.app.credits.small", reading: "401 credits · $4.99")
		XCTAssertEqual(app.cells.count, 5)
		XCTAssertFalse(
			app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'OpenRouter'"))
				.firstMatch.exists)
		capture(app, "zero-credits")
		TutorialHarness.returnToChat(app, maximumBackSteps: 1)
		TutorialHarness.wait(TutorialHarness.notice(app, reading: sentence))
		TutorialHarness.relaunchKeepingStore(app)
		TutorialHarness.wait(TutorialHarness.named(app, "chat.composer"))
		TutorialHarness.wait(TutorialHarness.notice(app, reading: sentence))
		TutorialHarness.waitForLabel(
			app, "Noted. I'll remember you ride with a group on Saturdays.")
		assertNoticeAction(app, buy: "Buy Credits")
		capture(app, "reopened-conversation")
		TutorialHarness.openRecords(app)
		TutorialHarness.waitForRecordCount(app, "memorySection", "memorySection 1")
		XCTAssertEqual(TutorialHarness.recordCount(app, "userMessage"), "userMessage 2")
		XCTAssertEqual(TutorialHarness.recordCount(app, "turnSettled"), "turnSettled 2")
		capture(app, "reopened-saved-memory-and-messages")
		TutorialHarness.returnToChat(app)
	}

	func testOutOfCreditsActionFitsInTheLongestTranslations() {
		for (language, locale, tag) in [("fr", "fr_FR", LanguageTag.fr), ("nl", "nl_NL", .nl)] {
			let app = XCUIApplication()
			let translated = CatalogPhrasebook(tag: tag)
			TutorialHarness.launch(app, language: language, locale: locale)
			TutorialHarness.completeOnboarding(app, language: tag)
			TutorialHarness.exchange(app, "fixture:fail 402")
			TutorialHarness.wait(
				TutorialHarness.notice(app, reading: translated.say(Catalog.creditsErrorExhausted)))
			assertNoticeAction(app, buy: translated.say(Catalog.chatTurnBuyCredits))
			capture(app, "exhausted-conversation-\(language)")
			app.terminate()
		}
	}

	private func assertNoticeAction(_ app: XCUIApplication, buy: String) {
		let buyCredits = TutorialHarness.named(app, "chat.turn.buyCredits")
		TutorialHarness.wait(buyCredits, until: .hittable)
		XCTAssertEqual(buyCredits.label, buy)
		XCTAssertTrue(app.windows.firstMatch.frame.contains(buyCredits.frame))
		XCTAssertEqual(app.buttons.matching(identifier: "chat.turn.buyCredits").count, 1)
		XCTAssertFalse(TutorialHarness.named(app, "chat.turn.tryAgain").exists)
	}

	private func capture(_ app: XCUIApplication, _ result: String) {
		TutorialHarness.attach(self, name: "billing-identity-\(result)", app: app)
	}
}
