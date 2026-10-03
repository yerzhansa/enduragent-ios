import EnduragentCoach
import XCTest

@MainActor
enum OnboardingConnectionProofScreen {
	static func resultMatrix(_ test: XCTestCase, dark: Bool) {
		let app = XCUIApplication()
		TutorialHarness.launch(app)
		enterConnect(app)
		TutorialHarness.named(app, "connect.connect").tap()
		TutorialHarness.waitForIdentifier(
			app, "connect.saved", reading: "Enter an intervals.icu API key.")
		XCTAssertFalse(TutorialHarness.named(app, "connect.continue").exists)
		capture(test, app, name: "onboarding-blank", dark: dark)
		save(app)
		assertAda(app)
		capture(test, app, name: "onboarding-saved", dark: dark)
		finishOnboarding(app)
		TutorialHarness.assertZeroFixtureRequests(app)

		TutorialHarness.launch(app, arguments: FixtureArguments(credentialWriteFault: .failOnce))
		enterConnect(app)
		TutorialHarness.type(app, "fixture", into: "connect.apiKey")
		TutorialHarness.named(app, "connect.connect").tap()
		TutorialHarness.waitForIdentifier(
			app, "connect.saved", reading: "The connection wasn't saved. Try again.")
		XCTAssertFalse(TutorialHarness.named(app, "connect.continue").exists)
		XCTAssertTrue(TutorialHarness.named(app, "connect.skip").exists)
		capture(test, app, name: "onboarding-not-saved", dark: dark)
		TutorialHarness.named(app, "connect.connect").tap()
		TutorialHarness.waitForIdentifier(app, "connect.saved", reading: "Saved")
		assertAda(app)
		capture(test, app, name: "onboarding-save-recovered", dark: dark)
		finishOnboarding(app)
		TutorialHarness.assertZeroFixtureRequests(app)

		for display in FixtureTrainingDisplay.allCases {
			TutorialHarness.launch(app, arguments: FixtureArguments(trainingDisplay: display))
			enterConnect(app)
			save(app)
			assertDisplay(app, display)
			capture(test, app, name: "onboarding-\(display.rawValue)", dark: dark)
			switch display {
			case .profileRejected, .profileRequestRejected, .wellnessRejected:
				let correction = TutorialHarness.named(app, "connect.displayAction")
				TutorialHarness.wait(correction, until: .hittable)
				XCTAssertEqual(correction.label, "Review connection")
				correction.tap()
				assertEmptyKey(app, identifier: "connect.apiKey", language: .en)
				save(app, key: "fixture-corrected")
				assertAda(app)
				capture(test, app, name: "onboarding-\(display.rawValue)-corrected", dark: dark)
			case .profileUnavailable, .wellnessUnavailable:
				let retry = TutorialHarness.named(app, "connect.displayAction")
				TutorialHarness.wait(retry, until: .hittable)
				XCTAssertEqual(retry.label, "Try again")
				retry.tap()
				assertAda(app)
				XCTAssertFalse(TutorialHarness.named(app, "connect.apiKey").exists)
				XCTAssertEqual(TutorialHarness.named(app, "connect.saved").label, "Saved")
				capture(test, app, name: "onboarding-\(display.rawValue)-recovered", dark: dark)
			case .emptyWellness, .partialWellness:
				XCTAssertFalse(TutorialHarness.named(app, "connect.displayAction").exists)
			}
			finishOnboarding(app)
			TutorialHarness.assertZeroFixtureRequests(app)
		}
	}

	static func connectLater(_ test: XCTestCase, dark: Bool) {
		let app = XCUIApplication()
		let phrasebook = CatalogPhrasebook(tag: .fr)
		TutorialHarness.launch(app, language: "ru,fr,en", locale: "fr_FR")
		enterConnect(app, language: .fr)
		TutorialHarness.type(app, "ab", into: "connect.apiKey")
		let skip = TutorialHarness.named(app, "connect.skip")
		TutorialHarness.scroll(app, to: skip)
		skip.tap()
		startChatting(app, language: .fr)
		TutorialHarness.exchange(app, "fixture:training-data")
		TutorialHarness.waitForLabel(app, "I can discuss general training. Connect in Settings")
		capture(test, app, name: "skipped-training-data-unavailable", dark: dark)
		TutorialHarness.openCredentials(app)
		XCTAssertEqual(
			TutorialHarness.named(app, "training.edit").label,
			phrasebook.say(Catalog.onboardingConnectAction))
		XCTAssertFalse(TutorialHarness.named(app, "training.apiKey").exists)
		TutorialHarness.named(app, "training.edit").tap()
		assertEmptyKey(app, identifier: "training.apiKey", language: .fr)
		TutorialHarness.type(app, "fixture", into: "training.apiKey")
		TutorialHarness.named(app, "training.save").tap()
		TutorialHarness.waitForIdentifier(
			app, "training.saved", reading: phrasebook.say(Catalog.planViewEndedSaved))
		TutorialHarness.waitForIdentifier(app, "training.athlete", reading: "Ada Kovač")
		TutorialHarness.waitForIdentifier(
			app, "training.fitness",
			reading: phrasebook.say(Catalog.onboardingConnectFitness, ["value": "42"]))
		capture(test, app, name: "settings-latin-key-saved", dark: dark)
		TutorialHarness.returnToChat(app)
		TutorialHarness.exchange(app, "fixture:training-data")
		TutorialHarness.waitForLabel(app, "I can read Ada Kovač's training profile and calendar.")
		TutorialHarness.waitForLabel(app, "I can discuss general training. Connect in Settings")
		capture(test, app, name: "connected-later-conversation-kept", dark: dark)
		TutorialHarness.relaunchKeepingStore(app)
		TutorialHarness.waitForLabel(app, "I can read Ada Kovač's training profile and calendar.")
		TutorialHarness.assertZeroFixtureRequests(app)
	}

	private static func enterConnect(_ app: XCUIApplication, language: LanguageTag = .en) {
		let phrasebook = CatalogPhrasebook(tag: language)
		TutorialHarness.waitForLabel(app, phrasebook.say(Catalog.onboardingNoticeHealth))
		TutorialHarness.named(app, "notice.continue").tap()
		assertEmptyKey(app, identifier: "connect.apiKey", language: language)
	}

	private static func save(_ app: XCUIApplication, key: String = "fixture") {
		TutorialHarness.type(app, key, into: "connect.apiKey")
		TutorialHarness.named(app, "connect.connect").tap()
		TutorialHarness.waitForIdentifier(app, "connect.saved", reading: "Saved")
		TutorialHarness.wait(TutorialHarness.named(app, "connect.continue"))
	}

	private static func assertDisplay(_ app: XCUIApplication, _ display: FixtureTrainingDisplay) {
		let notice: CatalogKey?
		switch display {
		case .profileRejected: notice = Catalog.connectErrorRejected
		case .profileRequestRejected: notice = Catalog.coachErrorIntervalsCredentials
		case .profileUnavailable: notice = Catalog.connectErrorProfileUnavailable
		case .wellnessRejected: notice = Catalog.connectErrorWellnessRejected
		case .wellnessUnavailable: notice = Catalog.connectErrorWellnessUnavailable
		case .emptyWellness: notice = Catalog.connectWellnessEmpty
		case .partialWellness: notice = nil
		}
		if let notice {
			TutorialHarness.waitForIdentifier(
				app, "connect.notice",
				reading: CatalogPhrasebook(tag: .en).say(notice, ["service": "intervals.icu"]))
		} else {
			TutorialHarness.waitForIdentifier(app, "connect.fitness", reading: "Fitness 42")
			XCTAssertFalse(TutorialHarness.named(app, "connect.notice").exists)
		}
		if display == .profileRejected || display == .profileRequestRejected
			|| display == .profileUnavailable
		{
			XCTAssertFalse(TutorialHarness.named(app, "connect.athleteName").exists)
		} else {
			TutorialHarness.waitForIdentifier(app, "connect.athleteName", reading: "Ada Kovač")
		}
		if display != .partialWellness {
			XCTAssertFalse(TutorialHarness.named(app, "connect.fitness").exists)
		}
		XCTAssertFalse(TutorialHarness.named(app, "connect.fatigue").exists)
		XCTAssertFalse(TutorialHarness.named(app, "connect.form").exists)
	}

	private static func assertAda(_ app: XCUIApplication) {
		TutorialHarness.waitForIdentifier(app, "connect.athleteName", reading: "Ada Kovač")
		TutorialHarness.waitForIdentifier(app, "connect.fitness", reading: "Fitness 42")
		TutorialHarness.waitForIdentifier(app, "connect.fatigue", reading: "Fatigue 49")
		TutorialHarness.waitForIdentifier(app, "connect.form", reading: "Form -7")
	}

	private static func assertEmptyKey(
		_ app: XCUIApplication, identifier: String, language: LanguageTag
	) {
		let key = app.secureTextFields[identifier]
		TutorialHarness.wait(key, until: .hittable)
		XCTAssertEqual(key.value as? String, key.placeholderValue)
		XCTAssertEqual(
			key.placeholderValue,
			CatalogPhrasebook(tag: language).say(Catalog.onboardingConnectApiKey))
	}

	private static func finishOnboarding(_ app: XCUIApplication) {
		let next = TutorialHarness.named(app, "connect.continue")
		TutorialHarness.scroll(app, to: next)
		next.tap()
		startChatting(app)
	}

	private static func startChatting(_ app: XCUIApplication, language: LanguageTag = .en) {
		TutorialHarness.wait(TutorialHarness.named(app, "starter.credits"))
		TutorialHarness.named(app, "starter.start").tap()
		TutorialHarness.agreeToProviderConsent(app, language: language)
		TutorialHarness.wait(TutorialHarness.named(app, "chat.composer"))
	}

	private static func capture(
		_ test: XCTestCase, _ app: XCUIApplication, name: String, dark: Bool
	) {
		let luminance = TutorialHarness.meanLuminance(app.screenshot())
		if dark { XCTAssertLessThan(luminance, 0.4) } else { XCTAssertGreaterThan(luminance, 0.4) }
		TutorialHarness.attach(test, name: "\(name)-\(dark ? "dark" : "light")", app: app)
	}
}
