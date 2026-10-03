import EnduragentCoach
import XCTest

@MainActor
final class AccessSettingsProof: XCTestCase {
	func testLeavingKeepsSavedOpenRouterAfterRelaunch() {
		let app = launch(access: .openRouter)
		TutorialHarness.exchange(app, TutorialHarness.weekQuestion)
		TutorialHarness.type(app, TutorialHarness.draft, into: "chat.composer")
		openAccess(app)
		assertChoice(app, credits: false)
		capture(app, "saved-openrouter")
		TutorialHarness.returnToChat(app)
		XCTAssertEqual(
			TutorialHarness.named(app, "chat.composer").value as? String, TutorialHarness.draft)
		TutorialHarness.relaunchKeepingStore(app)
		TutorialHarness.waitForLabel(app, TutorialHarness.weekQuestion)
		openAccess(app)
		assertChoice(app, credits: false)
		capture(app, "saved-openrouter-reopened")
		TutorialHarness.returnToChat(app)
		let composer = TutorialHarness.named(app, "chat.composer")
		composer.tap()
		composer.typeText(
			String(repeating: XCUIKeyboardKey.delete.rawValue, count: TutorialHarness.draft.count))
		TutorialHarness.type(app, "fixture:training-data", into: "chat.composer")
		TutorialHarness.named(app, "chat.send").tap()
		TutorialHarness.waitForLabel(
			app,
			"intervals.icu is not connected, so I can't read your training profile or calendar. I can discuss general training. Connect in Settings to use your data.",
			within: .turn)
		capture(app, "previous-method-tool-reply")
		TutorialHarness.assertZeroFixtureRequests(app)
	}

	func testCreditsSetupSelectsOnlyAfterPersistenceAndKeepsTheChoice() {
		let app = launch(access: .openRouterNeedsCredits)
		openAccess(app)
		assertChoice(app, credits: false)
		TutorialHarness.named(app, "access.credits").tap()
		TutorialHarness.waitForIdentifier(
			app, "consent.body",
			reading: phrasebook.say(
				Catalog.onboardingConsentBody,
				["model": "DeepSeek V4.1 Flash", "provider": "DeepSeek"]))
		TutorialHarness.agreeToProviderConsent(
			app, recipient: (model: "DeepSeek V4.1 Flash", provider: "DeepSeek"))
		openAccess(app)
		assertChoice(app, credits: true)
		capture(app, "credits-setup-succeeded")
		TutorialHarness.relaunchKeepingStore(app)
		TutorialHarness.wait(TutorialHarness.named(app, "chat.composer"))
		openAccess(app)
		assertChoice(app, credits: true)
		capture(app, "credits-choice-reopened")
		TutorialHarness.returnToChat(app)
		TutorialHarness.exchange(app, TutorialHarness.weekQuestion)
		TutorialHarness.assertZeroFixtureRequests(app)
	}

	func testSignInOutcomesKeepOrMoveTheSavedTickAndHeldTapsJoin() {
		let scenarios: [(FixtureSignInOutcome, FixtureCredentialWriteFault?)] = [
			(.success, nil), (.cancel, nil), (.rejectedCallback, nil), (.exchangeFailure, nil),
			(.held, nil), (.success, .failOnce), (.success, .failSelection),
		]
		for (outcome, fault) in scenarios {
			let app = launch(writeFault: fault, signIn: outcome)
			openAccess(app)
			assertChoice(app, credits: true)
			let signIn = TutorialHarness.named(app, "access.openRouter")
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
			if succeeded {
				TutorialHarness.waitForIdentifier(
					app, "consent.body",
					reading: phrasebook.say(
						Catalog.onboardingConsentBody,
						["model": "DeepSeek V4.1 Flash", "provider": "DeepSeek"]))
				TutorialHarness.waitForIdentifier(
					app, "consent.modelRequestCount", reading: "0 model requests")
				capture(app, "sign-in-\(outcome.rawValue)-consent")
				TutorialHarness.agreeToProviderConsent(app)
				openAccess(app)
			} else {
				let key =
					fault != nil
					? Catalog.reviewSaveFailed
					: outcome == .cancel
						? Catalog.accessSignInCancelled : Catalog.accessSignInIncomplete
				waitForNotice(app, phrasebook.say(key))
			}
			assertChoice(app, credits: !succeeded)
			capture(app, "sign-in-\(outcome.rawValue)-\(fault?.rawValue ?? "saved")")
			TutorialHarness.returnToChat(app)
			TutorialHarness.relaunchKeepingStore(app)
			TutorialHarness.wait(TutorialHarness.named(app, "chat.composer"))
			openAccess(app)
			assertChoice(app, credits: !succeeded)
			TutorialHarness.returnToChat(app)
			TutorialHarness.exchange(app, TutorialHarness.weekQuestion)
			TutorialHarness.assertZeroFixtureRequests(app)
			app.terminate()
		}
	}

	func testFailedChoiceWriteKeepsOpenRouterSelected() {
		let app = launch(access: .openRouter, writeFault: .failOnce)
		openAccess(app)
		TutorialHarness.named(app, "access.credits").tap()
		waitForNotice(app, phrasebook.say(Catalog.reviewSaveFailed))
		assertChoice(app, credits: false)
		capture(app, "choice-write-failed")
		TutorialHarness.relaunchKeepingStore(app)
		TutorialHarness.wait(TutorialHarness.named(app, "chat.composer"))
		openAccess(app)
		assertChoice(app, credits: false)
		capture(app, "failed-choice-reopened")
		TutorialHarness.returnToChat(app)
		TutorialHarness.exchange(app, TutorialHarness.weekQuestion)
		TutorialHarness.assertZeroFixtureRequests(app)
	}

	func testProvisioningAndCredentialWriteFailuresKeepOpenRouterSelected() {
		for writeFails in [false, true] {
			let app = launch(
				access: .openRouterNeedsCredits, credits: writeFails ? .ready : .provisioningFailed,
				writeFault: writeFails ? .failOnce : nil)
			openAccess(app)
			TutorialHarness.named(app, "access.credits").tap()
			waitForNotice(
				app,
				phrasebook.say(
					writeFails
						? Catalog.accessErrorStorageUnavailable : Catalog.creditsErrorUnavailable))
			assertChoice(app, credits: false)
			capture(app, writeFails ? "credential-write-failed" : "provisioning-failed")
			TutorialHarness.returnToChat(app)
			TutorialHarness.exchange(app, TutorialHarness.weekQuestion)
			TutorialHarness.assertZeroFixtureRequests(app)
			app.terminate()
		}
	}

	func testDepletedAndUnavailableCreditsOfferDisabledBuyAndAccessScreen() {
		for depleted in [true, false] {
			let app = launch(credits: depleted ? .zero : .unavailable)
			TutorialHarness.openSettings(app)
			TutorialHarness.named(app, "settings.credits").tap()
			TutorialHarness.waitForIdentifier(
				app, "credits.notice",
				reading: phrasebook.say(
					depleted ? Catalog.creditsErrorExhausted : Catalog.creditsErrorUnavailable))
			if depleted {
				TutorialHarness.waitForIdentifier(app, "credits.balance", reading: "0 credits")
			} else {
				XCTAssertFalse(TutorialHarness.named(app, "credits.balance").exists)
			}
			let buy = app.buttons.matching(
				NSPredicate(format: "label == %@", phrasebook.say(Catalog.creditsBuy)))
			XCTAssertEqual(buy.count, 2)
			for button in buy.allElementsBoundByIndex { XCTAssertFalse(button.isEnabled) }
			XCTAssertEqual(
				TutorialHarness.named(app, "credits.note").label,
				phrasebook.say(Catalog.creditsTesters))
			capture(app, depleted ? "credits-depleted" : "credits-unavailable")
			TutorialHarness.named(app, "credits.switchToOpenRouter").tap()
			assertChoice(app, credits: true)
			capture(app, "switch-to-openrouter-\(depleted ? "depleted" : "unavailable")")
			TutorialHarness.returnToChat(app)
			TutorialHarness.assertZeroFixtureRequests(app)
			app.terminate()
		}
	}

	func testMissingUnavailableAndMalformedModelAccessReachAccessScreen() {
		for keychain in [FixtureKeychainPolicy.empty, .unavailable, .malformedAccess] {
			let app = launch(keychain: keychain)
			let key: CatalogKey =
				switch keychain {
				case .unavailable: Catalog.accessErrorStorageUnavailable
				case .malformedAccess: Catalog.accessErrorMalformed
				default: Catalog.accessErrorNotConfigured
				}
			TutorialHarness.send(app, TutorialHarness.weekQuestion)
			TutorialHarness.wait(TutorialHarness.notice(app, reading: phrasebook.say(key)))
			capture(app, "access-notice-\(keychain.rawValue)")
			TutorialHarness.named(app, "chat.turn.chooseAccessMethod").tap()
			assertChoice(app, credits: true)
			waitForNotice(app, phrasebook.say(key))
			capture(app, "access-destination-\(keychain.rawValue)")
			XCTAssertFalse(TutorialHarness.named(app, "connect.apiKey").exists)
			TutorialHarness.returnToChat(app)
			TutorialHarness.waitForLabel(app, TutorialHarness.weekQuestion)
			TutorialHarness.assertZeroFixtureRequests(app)
			app.terminate()
		}
	}

	func testBuyCreditsAndSignInAgainRecoveryPreserveTheConversation() {
		for openRouter in [false, true] {
			let app = launch(access: openRouter ? .openRouter : .credits)
			TutorialHarness.exchange(app, openRouter ? "fixture:fail 401" : "fixture:fail 402")
			let action = TutorialHarness.named(
				app, openRouter ? "chat.turn.signInAgain" : "chat.turn.buyCredits")
			TutorialHarness.wait(action, until: .hittable)
			action.tap()
			if openRouter {
				assertChoice(app, credits: false)
				capture(app, "sign-in-again-destination")
			} else {
				TutorialHarness.wait(TutorialHarness.named(app, "credits.balance"))
				capture(app, "buy-credits-destination")
				TutorialHarness.named(app, "credits.switchToOpenRouter").tap()
				assertChoice(app, credits: true)
				capture(app, "buy-credits-switch-destination")
			}
			TutorialHarness.returnToChat(app)
			TutorialHarness.wait(action)
			TutorialHarness.relaunchKeepingStore(app)
			TutorialHarness.wait(action)
			openAccess(app)
			assertChoice(app, credits: !openRouter)
			TutorialHarness.returnToChat(app)
			TutorialHarness.assertZeroFixtureRequests(app)
			app.terminate()
		}
	}

	private var phrasebook: CatalogPhrasebook { CatalogPhrasebook(tag: .en) }

	private func launch(
		access: FixtureAccessMethod = .credits, credits: FixtureCreditsOutcome = .ready,
		writeFault: FixtureCredentialWriteFault? = nil, keychain: FixtureKeychainPolicy = .unlocked,
		signIn: FixtureSignInOutcome = .cancel
	) -> XCUIApplication {
		let app = XCUIApplication()
		TutorialHarness.launch(
			app,
			arguments: FixtureArguments(
				keychain: keychain, onboarded: true, credentialWriteFault: writeFault,
				accessMethod: access, creditsOutcome: credits, signInOutcome: signIn))
		TutorialHarness.agreeToProviderConsent(app)
		return app
	}

	private func openAccess(_ app: XCUIApplication) {
		TutorialHarness.openSettings(app)
		let access = TutorialHarness.named(app, "settings.accessMethod")
		TutorialHarness.wait(access, until: .hittable)
		access.tap()
		TutorialHarness.wait(app.navigationBars[phrasebook.say(Catalog.accessTitle)])
	}

	private func assertChoice(_ app: XCUIApplication, credits: Bool) {
		let creditsChoice = TutorialHarness.named(app, "access.credits")
		let openRouter = TutorialHarness.named(app, "access.openRouter")
		TutorialHarness.wait(creditsChoice, until: .hittable)
		TutorialHarness.wait(openRouter, until: .hittable)
		TutorialHarness.wait(
			until: {
				creditsChoice.isSelected == credits && openRouter.isSelected != credits
			}, message: "The access screen did not mark the saved method")
		XCTAssertEqual(creditsChoice.label, phrasebook.say(Catalog.creditsTitle))
		XCTAssertEqual(openRouter.label, phrasebook.say(Catalog.accessSignIn))
		XCTAssertFalse(TutorialHarness.named(app, "connect.apiKey").exists)
	}

	private func waitForNotice(_ app: XCUIApplication, _ line: String) {
		TutorialHarness.waitForIdentifier(app, "access.notice", reading: line)
	}

	private func capture(_ app: XCUIApplication, _ result: String) {
		let appearance = TutorialHarness.meanLuminance(app.screenshot()) < 0.4 ? "dark" : "light"
		TutorialHarness.attach(self, name: "access-settings-\(result)-\(appearance)", app: app)
	}
}
