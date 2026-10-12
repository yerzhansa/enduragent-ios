import EnduragentCoach
import XCTest

extension TutorialHarness {
	static func completeOnboarding(
		_ app: XCUIApplication, language: LanguageTag = .en, captureSetup: () -> Void = {}
	) {
		let phrasebook = CatalogPhrasebook(tag: language)
		let notice = text(app, containing: phrasebook.say(Catalog.onboardingNoticeHealth))
		guard wait(notice) else { return }
		named(app, "notice.continue").tap()
		let key = named(app, "connect.apiKey")
		guard waitForProgress(app, to: "the connect step opening", until: { key.exists }) else {
			return
		}
		key.tap()
		key.typeText("fixture")
		named(app, "connect.connect").tap()
		wait(named(app, "connect.athleteName"))
		XCTAssertEqual(named(app, "connect.athleteName").label, "Ada Kovač")
		wait(named(app, "connect.fitness"))
		XCTAssertEqual(
			named(app, "connect.fitness").label,
			phrasebook.say(Catalog.onboardingConnectFitness, ["value": "42"]))
		wait(named(app, "connect.fatigue"))
		XCTAssertEqual(
			named(app, "connect.fatigue").label,
			phrasebook.say(Catalog.onboardingConnectFatigue, ["value": "49"]))
		wait(named(app, "connect.form"))
		XCTAssertEqual(
			named(app, "connect.form").label,
			phrasebook.say(Catalog.onboardingConnectForm, ["value": "-7"]))
		captureSetup()
		named(app, "connect.continue").tap()
		wait(named(app, "starter.credits"))
		XCTAssertEqual(
			named(app, "starter.credits").label,
			phrasebook.say(Catalog.creditsBalance, count: 200, ["formattedCount": "200"]))
		named(app, "starter.start").tap()
		agreeToProviderConsent(app, language: language)
		wait(named(app, "chat.composer"))
		wait(named(app, "chat.welcome"))
	}

	static func startUnconnected(_ app: XCUIApplication) {
		waitForLabel(app, notice)
		named(app, "notice.continue").tap()
		let skip = named(app, "connect.skip")
		wait(skip)
		skip.tap()
		let start = named(app, "starter.start")
		wait(start)
		start.tap()
		agreeToProviderConsent(app)
	}

	static func agreeToProviderConsent(
		_ app: XCUIApplication, language: LanguageTag = .en,
		recipient: (model: String, provider: String)? = nil
	) {
		let phrasebook = CatalogPhrasebook(tag: language)
		let variables =
			recipient.map { ["model": $0.model, "provider": $0.provider] }
			?? consentVariables(app)
		let accept = named(app, "consent.accept")
		wait(accept)
		XCTAssertEqual(
			named(app, "consent.body").label,
			phrasebook.say(Catalog.onboardingConsentBody, variables))
		XCTAssertEqual(accept.label, phrasebook.say(Catalog.onboardingConsentAccept))
		XCTAssertTrue(named(app, "consent.decline").exists)
		accept.tap()
		wait(named(app, "chat.composer"))
	}
	private static func consentVariables(_ app: XCUIApplication) -> [String: String] {
		var arguments = FixtureArguments()
		do {
			try arguments.update(from: app.launchArguments)
		} catch {
			XCTFail("Invalid fixture arguments: \(error)")
		}
		if arguments.accessMethod == .openRouter
			|| arguments.accessMethod == .openRouterNeedsCredits
		{
			return ["model": "fixture/openrouter-model", "provider": "Fixture Host"]
		}
		if arguments.accessMethod == .syncedOpenRouter {
			return ["model": "Claude Sonnet 4.5", "provider": "Anthropic"]
		}
		return ["model": "DeepSeek V4.1 Flash", "provider": "DeepSeek"]
	}

}
