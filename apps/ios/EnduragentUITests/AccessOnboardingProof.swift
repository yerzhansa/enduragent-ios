import EnduragentCoach
import XCTest

@MainActor
final class AccessOnboardingProof: XCTestCase {
	func testStarterCreditsThenStartChattingAndReopen() {
		let app = launch(access: .creditsNeedsSetup)
		assertStarterScreen(app, reading: "200 credits")
		capture(app, "starter-credits")
		finishOnboarding(app)
		TutorialHarness.relaunchKeepingStore(app)
		TutorialHarness.wait(TutorialHarness.named(app, "chat.composer"))
		TutorialHarness.exchange(app, TutorialHarness.weekQuestion)
	}

	func testStarterFailuresShowTheirSentenceAndStillStartChatting() {
		let scenarios: [(String, FixtureCreditsOutcome, FixtureCredentialWriteFault?, CatalogKey)] =
			[
				("unavailable", .unavailable, nil, Catalog.creditsErrorUnavailable),
				("provisioning", .provisioningFailed, nil, Catalog.creditsErrorUnavailable),
				("already-granted", .alreadyGranted, nil, Catalog.onboardingStarterAlreadyGranted),
				("credential-write", .ready, .failOnce, Catalog.accessErrorStorageUnavailable),
			]
		for (name, outcome, fault, expected) in scenarios {
			let app = launch(access: .creditsNeedsSetup, credits: outcome, writeFault: fault)
			assertStarterScreen(app, reading: phrasebook.say(expected))
			capture(app, name)
			finishOnboarding(app)
			TutorialHarness.wait(TutorialHarness.named(app, "chat.composer"))
			app.terminate()
		}
	}

	func testSavedBuild9OpenRouterChoiceChatsOnCredits() {
		let app = launch(access: .build9OpenRouter)
		assertStarterScreen(app, reading: "200 credits")
		finishOnboarding(app)
		TutorialHarness.exchange(app, TutorialHarness.weekQuestion)
		TutorialHarness.openSettings(app)
		TutorialHarness.wait(TutorialHarness.named(app, "settings.credits"), until: .hittable)
		XCTAssertFalse(TutorialHarness.named(app, "settings.accessMethod").exists)
		XCTAssertFalse(TutorialHarness.named(app, "settings.model").exists)
		capture(app, "build9-openrouter-settings")
	}

	private var phrasebook: CatalogPhrasebook { CatalogPhrasebook(tag: .en) }

	private func launch(
		access: FixtureAccessMethod, credits: FixtureCreditsOutcome = .ready,
		writeFault: FixtureCredentialWriteFault? = nil
	) -> XCUIApplication {
		let app = XCUIApplication()
		TutorialHarness.launch(
			app,
			arguments: FixtureArguments(
				credentialWriteFault: writeFault, accessMethod: access, creditsOutcome: credits))
		TutorialHarness.wait(TutorialHarness.named(app, "notice.continue"))
		TutorialHarness.named(app, "notice.continue").tap()
		TutorialHarness.wait(TutorialHarness.named(app, "connect.skip"))
		TutorialHarness.named(app, "connect.skip").tap()
		TutorialHarness.wait(TutorialHarness.named(app, "starter.start"), until: .hittable)
		return app
	}

	private func assertStarterScreen(_ app: XCUIApplication, reading line: String) {
		TutorialHarness.wait(app.navigationBars[phrasebook.say(Catalog.creditsTitle)])
		TutorialHarness.waitForIdentifier(app, "starter.credits", reading: line)
		let start = TutorialHarness.named(app, "starter.start")
		XCTAssertEqual(start.label, phrasebook.say(Catalog.onboardingStarterStart))
		XCTAssertLessThan(
			TutorialHarness.named(app, "starter.credits").frame.maxY, start.frame.minY)
		XCTAssertEqual(app.buttons.count, 1)
		XCTAssertFalse(
			app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'OpenRouter'"))
				.firstMatch.exists)
		XCTAssertFalse(app.textFields.firstMatch.exists)
	}

	private func finishOnboarding(_ app: XCUIApplication) {
		TutorialHarness.named(app, "starter.start").tap()
		TutorialHarness.agreeToProviderConsent(
			app, recipient: (model: "DeepSeek V4.1 Flash", provider: "DeepInfra"))
	}

	private func capture(_ app: XCUIApplication, _ result: String) {
		TutorialHarness.attach(self, name: "access-onboarding-\(result)", app: app)
	}
}
