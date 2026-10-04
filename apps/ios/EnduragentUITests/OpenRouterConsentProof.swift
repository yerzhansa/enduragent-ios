import EnduragentCoach
import XCTest

@MainActor
final class OpenRouterConsentProof: XCTestCase {
	func testFirstSignInNamesTheCreditsModelBeforeAnyRequest() {
		let app = XCUIApplication()
		TutorialHarness.launch(app, arguments: FixtureArguments(signInOutcome: .success))
		TutorialHarness.wait(TutorialHarness.named(app, "notice.continue"), until: .hittable)
		TutorialHarness.named(app, "notice.continue").tap()
		TutorialHarness.wait(TutorialHarness.named(app, "connect.skip"), until: .hittable)
		TutorialHarness.named(app, "connect.skip").tap()
		TutorialHarness.wait(TutorialHarness.named(app, "starter.openRouter"), until: .hittable)
		TutorialHarness.named(app, "starter.openRouter").tap()
		TutorialHarness.wait(
			until: { TutorialHarness.named(app, "starter.openRouter").isSelected },
			message: "Successful first sign-in did not mark OpenRouter")
		TutorialHarness.wait(TutorialHarness.named(app, "starter.start"), until: .hittable)
		TutorialHarness.named(app, "starter.start").tap()
		assertDisclosure(app, model: "DeepSeek V4.1 Flash", provider: "DeepSeek")
		capture(app, "first-sign-in")
		TutorialHarness.named(app, "consent.decline").tap()
		TutorialHarness.wait(TutorialHarness.named(app, "consent.resume"), until: .hittable)
		assertDisclosure(app, model: "DeepSeek V4.1 Flash", provider: "DeepSeek")
		capture(app, "first-sign-in-declined")
		TutorialHarness.named(app, "consent.resume").tap()
		TutorialHarness.wait(TutorialHarness.named(app, "chat.composer"))
		TutorialHarness.exchange(app, TutorialHarness.weekQuestion)
		TutorialHarness.assertZeroFixtureRequests(app)
	}

	func testAnotherDevicesSyncedChoiceNamesItsProviderAndAsksAgainAfterDecline() {
		let app = XCUIApplication()
		TutorialHarness.launch(
			app, arguments: FixtureArguments(onboarded: true, accessMethod: .syncedOpenRouter))
		assertDisclosure(app, model: "Claude Sonnet 4.5", provider: "Anthropic")
		capture(app, "synced-selection")
		TutorialHarness.named(app, "consent.decline").tap()
		TutorialHarness.wait(TutorialHarness.named(app, "consent.resume"))
		assertDisclosure(app, model: "Claude Sonnet 4.5", provider: "Anthropic")
		TutorialHarness.relaunchKeepingStore(app)
		assertDisclosure(app, model: "Claude Sonnet 4.5", provider: "Anthropic")
		capture(app, "synced-selection-reopened")
		TutorialHarness.agreeToProviderConsent(app)
		TutorialHarness.exchange(app, TutorialHarness.weekQuestion)
		TutorialHarness.assertZeroFixtureRequests(app)
	}

	private func assertDisclosure(_ app: XCUIApplication, model: String, provider: String) {
		TutorialHarness.waitForIdentifier(
			app, "consent.body",
			reading: CatalogPhrasebook(tag: .en).say(
				Catalog.onboardingConsentBody, ["model": model, "provider": provider]))
		TutorialHarness.waitForIdentifier(
			app, "consent.modelRequestCount", reading: "0 model requests")
		XCTAssertFalse(TutorialHarness.named(app, "chat.composer").exists)
	}

	private func capture(_ app: XCUIApplication, _ scenario: String) {
		let appearance = TutorialHarness.meanLuminance(app.screenshot()) < 0.4 ? "dark" : "light"
		TutorialHarness.attach(self, name: "openrouter-consent-\(scenario)-\(appearance)", app: app)
	}
}
