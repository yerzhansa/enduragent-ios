import EnduragentCoach
import XCTest

@MainActor
final class AccessOnboardingProof: XCTestCase {
	func testCreditsFirstThenSignInAndPersistedChoice() {
		let app = launch(access: .openRouterNeedsCredits)
		assertStarterChoices(app, credits: false)
		TutorialHarness.waitForIdentifier(app, "starter.credits", reading: "200 credits")
		assertFilledMethod(app, credits: false)
		capture(app, "grant-before-choice")
		TutorialHarness.named(app, "starter.useCredits").tap()
		waitForChoice(app, credits: true, starter: true)
		assertFilledMethod(app, credits: true)
		capture(app, "credits-chosen")
		TutorialHarness.named(app, "starter.start").tap()
		TutorialHarness.agreeToProviderConsent(
			app, recipient: (model: "DeepSeek V4.1 Flash", provider: "DeepSeek"))
		openAccess(app)
		waitForChoice(app, credits: true)
		capture(app, "settings-credits")
		TutorialHarness.returnToChat(app)
		TutorialHarness.relaunchKeepingStore(app)
		TutorialHarness.wait(TutorialHarness.named(app, "chat.composer"))
		openAccess(app)
		waitForChoice(app, credits: true)
		capture(app, "reopened-credits")
		TutorialHarness.returnToChat(app)
		TutorialHarness.exchange(app, TutorialHarness.weekQuestion)
	}

	func testFailuresKeepPreviousChoiceAndShowTruthfulResults() {
		for fault in [
			"unavailable", "provisioning", "credential-write", "already-granted", "selection-write",
			"sign-in-openrouter", "sign-in-credits",
		] {
			let creditsSelected = fault == "sign-in-credits"
			let method: FixtureAccessMethod =
				creditsSelected
				? .credits
				: ["credential-write", "provisioning", "already-granted"].contains(fault)
					? .openRouterNeedsCredits : .openRouter
			let outcome: FixtureCreditsOutcome =
				switch fault {
				case "unavailable": .unavailable
				case "provisioning": .provisioningFailed
				case "already-granted", "selection-write": .alreadyGranted
				default: .ready
				}
			let app = launch(
				access: method, credits: outcome,
				writeFault: ["credential-write", "selection-write"].contains(fault)
					? .failOnce : nil)
			assertStarterChoices(app, credits: creditsSelected)
			if fault == "selection-write" {
				TutorialHarness.waitForIdentifier(app, "starter.credits", reading: "200 credits")
				TutorialHarness.named(app, "starter.useCredits").tap()
			} else if fault.hasPrefix("sign-in") {
				TutorialHarness.named(app, "starter.openRouter").tap()
			} else if fault == "provisioning" || fault == "already-granted" {
				TutorialHarness.named(app, "starter.useCredits").tap()
			}
			let expected: CatalogKey =
				switch fault {
				case "credential-write": Catalog.accessErrorStorageUnavailable
				case "already-granted": Catalog.onboardingStarterAlreadyGranted
				case "selection-write": Catalog.reviewSaveFailed
				case "sign-in-openrouter", "sign-in-credits": Catalog.accessSignInCancelled
				default: Catalog.creditsErrorUnavailable
				}
			TutorialHarness.waitForIdentifier(
				app, "starter.credits", reading: phrasebook.say(expected))
			waitForChoice(app, credits: creditsSelected, starter: true)
			capture(app, fault)
			finishOnboarding(app)
			openAccess(app)
			waitForChoice(app, credits: creditsSelected)
			XCTAssertFalse(TutorialHarness.named(app, "access.notice").exists)
			capture(app, "settings-after-\(fault)")
			TutorialHarness.returnToChat(app)
			TutorialHarness.relaunchKeepingStore(app)
			TutorialHarness.wait(TutorialHarness.named(app, "chat.composer"))
			openAccess(app)
			waitForChoice(app, credits: creditsSelected)
			TutorialHarness.returnToChat(app)
			TutorialHarness.exchange(app, TutorialHarness.weekQuestion)
			app.terminate()
		}
	}

	func testEverySignInOutcomeShowsTheSavedChoiceAndHeldTapsJoin() {
		let scenarios: [(FixtureSignInOutcome, FixtureCredentialWriteFault?)] = [
			(.success, nil), (.cancel, nil), (.rejectedCallback, nil), (.exchangeFailure, nil),
			(.held, nil), (.success, .failOnce), (.success, .failSelection),
		]
		for (outcome, fault) in scenarios {
			let app = launch(
				access: .credits, credits: .alreadyGranted, writeFault: fault, signIn: outcome)
			waitForChoice(app, credits: true, starter: true)
			let signIn = TutorialHarness.named(app, "starter.openRouter")
			signIn.tap()
			if outcome == .held {
				TutorialHarness.waitForIdentifier(
					app, "fixture.signInCount", reading: "1 authorizations")
				XCTAssertTrue(signIn.isEnabled)
				signIn.tap()
				XCTAssertEqual(
					TutorialHarness.named(app, "fixture.signInCount").label, "1 authorizations")
				capture(app, "joined-held-sign-in")
				TutorialHarness.named(app, "fixture.completeSignIn").tap()
			}
			let succeeded = fault == nil && (outcome == .success || outcome == .held)
			if !succeeded {
				let key =
					fault != nil
					? Catalog.reviewSaveFailed
					: outcome == .cancel
						? Catalog.accessSignInCancelled : Catalog.accessSignInIncomplete
				TutorialHarness.waitForIdentifier(
					app, "starter.credits", reading: phrasebook.say(key))
			}
			waitForChoice(app, credits: !succeeded, starter: true)
			capture(app, "sign-in-\(outcome.rawValue)-\(fault?.rawValue ?? "saved")")
			TutorialHarness.named(app, "starter.start").tap()
			TutorialHarness.waitForIdentifier(
				app, "consent.body",
				reading: phrasebook.say(
					Catalog.onboardingConsentBody,
					["model": "DeepSeek V4.1 Flash", "provider": "DeepSeek"]))
			TutorialHarness.waitForIdentifier(
				app, "consent.modelRequestCount", reading: "0 model requests")
			capture(app, "sign-in-\(outcome.rawValue)-consent")
			TutorialHarness.agreeToProviderConsent(app)
			TutorialHarness.relaunchKeepingStore(app)
			TutorialHarness.wait(TutorialHarness.named(app, "chat.composer"))
			openAccess(app)
			waitForChoice(app, credits: !succeeded)
			TutorialHarness.returnToChat(app)
			TutorialHarness.exchange(app, TutorialHarness.weekQuestion)
			app.terminate()
		}
	}

	private var phrasebook: CatalogPhrasebook { CatalogPhrasebook(tag: .en) }

	private func launch(
		access: FixtureAccessMethod, credits: FixtureCreditsOutcome = .ready,
		writeFault: FixtureCredentialWriteFault? = nil, signIn: FixtureSignInOutcome = .cancel
	) -> XCUIApplication {
		let app = XCUIApplication()
		TutorialHarness.launch(
			app,
			arguments: FixtureArguments(
				credentialWriteFault: writeFault, accessMethod: access, creditsOutcome: credits,
				signInOutcome: signIn))
		TutorialHarness.wait(TutorialHarness.named(app, "notice.continue"))
		TutorialHarness.named(app, "notice.continue").tap()
		TutorialHarness.wait(TutorialHarness.named(app, "connect.skip"))
		TutorialHarness.named(app, "connect.skip").tap()
		TutorialHarness.wait(TutorialHarness.named(app, "starter.start"), until: .hittable)
		return app
	}

	private func assertStarterChoices(_ app: XCUIApplication, credits: Bool) {
		let creditsChoice = TutorialHarness.named(app, "starter.useCredits")
		let grant = TutorialHarness.named(app, "starter.credits")
		let openRouter = TutorialHarness.named(app, "starter.openRouter")
		TutorialHarness.wait(creditsChoice, until: .hittable)
		TutorialHarness.wait(grant)
		TutorialHarness.wait(openRouter, until: .hittable)
		XCTAssertEqual(creditsChoice.label, phrasebook.say(Catalog.creditsTitle))
		XCTAssertEqual(openRouter.label, phrasebook.say(Catalog.accessSignIn))
		XCTAssertLessThan(creditsChoice.frame.maxY, grant.frame.minY)
		XCTAssertLessThan(grant.frame.maxY, openRouter.frame.minY)
		XCTAssertEqual(app.buttons.count, 3)
		XCTAssertFalse(app.textFields.firstMatch.exists)
		XCTAssertFalse(app.secureTextFields.firstMatch.exists)
		waitForChoice(app, credits: credits, starter: true)
	}

	private func waitForChoice(_ app: XCUIApplication, credits: Bool, starter: Bool = false) {
		let creditsChoice = TutorialHarness.named(
			app, starter ? "starter.useCredits" : "access.credits")
		let openRouter = TutorialHarness.named(
			app, starter ? "starter.openRouter" : "access.openRouter")
		TutorialHarness.wait(creditsChoice, until: .hittable)
		TutorialHarness.wait(openRouter, until: starter ? .exists : .hittable)
		TutorialHarness.wait(
			until: { creditsChoice.isSelected == credits && openRouter.isSelected != credits },
			message: "The screen did not mark the saved access method")
	}

	private func assertFilledMethod(_ app: XCUIApplication, credits: Bool) {
		let creditsChoice = TutorialHarness.named(app, "starter.useCredits")
		let openRouter = TutorialHarness.named(app, "starter.openRouter")
		TutorialHarness.wait(creditsChoice, until: .enabled)
		TutorialHarness.wait(openRouter, until: .enabled)
		let page = TutorialHarness.meanLuminance(app.screenshot())
		let chosen = TutorialHarness.meanLuminance(
			(credits ? creditsChoice : openRouter).screenshot())
		let other = TutorialHarness.meanLuminance(
			(credits ? openRouter : creditsChoice).screenshot())
		XCTAssertGreaterThan(
			abs(chosen - page), abs(other - page) + 0.1,
			"The chosen access method is not the filled button")
	}

	private func finishOnboarding(_ app: XCUIApplication) {
		TutorialHarness.named(app, "starter.start").tap()
		TutorialHarness.agreeToProviderConsent(app)
	}

	private func openAccess(_ app: XCUIApplication) {
		TutorialHarness.openSettings(app)
		let access = TutorialHarness.named(app, "settings.accessMethod")
		TutorialHarness.wait(access, until: .hittable)
		access.tap()
		TutorialHarness.wait(app.navigationBars[phrasebook.say(Catalog.accessTitle)])
	}

	private func capture(_ app: XCUIApplication, _ result: String) {
		TutorialHarness.attach(self, name: "access-onboarding-\(result)", app: app)
	}
}
