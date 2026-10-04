import EnduragentCoach
import XCTest

@MainActor
final class OpenRouterAccessProof: XCTestCase {
	func testSettingsSignInAndCancelKeepSavedMarksAndToolRepliesAfterRelaunch() {
		for success in [true, false] {
			let app = XCUIApplication()
			TutorialHarness.launch(
				app,
				arguments: FixtureArguments(
					onboarded: true, signInOutcome: success ? .success : .cancel))
			TutorialHarness.agreeToProviderConsent(app)
			TutorialHarness.exchange(app, "Earlier message")
			openAccess(app)
			assertChoice(app, openRouter: false)
			TutorialHarness.named(app, "access.openRouter").tap()
			if success {
				TutorialHarness.agreeToProviderConsent(app)
				openAccess(app)
			} else {
				TutorialHarness.waitForIdentifier(
					app, "access.notice", reading: phrasebook.say(Catalog.accessSignInCancelled))
			}
			waitForChoice(app, openRouter: success)
			capture(app, "settings-\(success ? "signed-in" : "cancelled")")
			TutorialHarness.returnToChat(app)
			TutorialHarness.relaunchKeepingStore(app)
			TutorialHarness.wait(TutorialHarness.named(app, "chat.composer"))
			openAccess(app)
			assertChoice(app, openRouter: success)
			capture(app, "settings-reopened-\(success)")
			TutorialHarness.returnToChat(app)
			proveToolReply(app)
			app.terminate()
		}
	}

	func testOnboardingSignInAndCancelKeepSavedMarksAndToolRepliesAfterRelaunch() {
		for success in [true, false] {
			let app = XCUIApplication()
			TutorialHarness.launch(
				app,
				arguments: FixtureArguments(
					accessMethod: success ? .credits : .openRouter,
					signInOutcome: success ? .success : .cancel))
			TutorialHarness.wait(TutorialHarness.named(app, "notice.continue"), until: .hittable)
			TutorialHarness.named(app, "notice.continue").tap()
			TutorialHarness.wait(TutorialHarness.named(app, "connect.skip"), until: .hittable)
			TutorialHarness.named(app, "connect.skip").tap()
			TutorialHarness.wait(TutorialHarness.named(app, "starter.openRouter"), until: .hittable)
			XCTAssertEqual(TutorialHarness.named(app, "starter.openRouter").isSelected, !success)
			TutorialHarness.named(app, "starter.openRouter").tap()
			if !success {
				TutorialHarness.waitForIdentifier(
					app, "starter.credits", reading: phrasebook.say(Catalog.accessSignInCancelled))
			}
			TutorialHarness.wait(
				until: { TutorialHarness.named(app, "starter.start").isEnabled },
				message: "Sign-in did not finish")
			XCTAssertTrue(TutorialHarness.named(app, "starter.openRouter").isSelected)
			capture(app, "onboarding-\(success ? "signed-in" : "cancelled")")
			TutorialHarness.named(app, "starter.start").tap()
			TutorialHarness.agreeToProviderConsent(
				app,
				recipient: success
					? (model: "DeepSeek V4.1 Flash", provider: "DeepSeek")
					: (model: "fixture/openrouter-model", provider: "Fixture Host"))
			TutorialHarness.relaunchKeepingStore(app)
			TutorialHarness.wait(TutorialHarness.named(app, "chat.composer"))
			openAccess(app)
			assertChoice(app, openRouter: true)
			capture(app, "onboarding-reopened-\(success)")
			TutorialHarness.returnToChat(app)
			proveToolReply(app)
			app.terminate()
		}
	}

	private func proveToolReply(_ app: XCUIApplication) {
		TutorialHarness.exchange(app, "fixture:training-data")
		TutorialHarness.waitForLabel(
			app,
			"intervals.icu is not connected, so I can't read your training profile or calendar. I can discuss general training. Connect in Settings to use your data.",
			within: .turn)
		capture(app, "tool-backed-reply")
		TutorialHarness.assertZeroFixtureRequests(app)
	}

	private func openAccess(_ app: XCUIApplication) {
		TutorialHarness.openSettings(app)
		TutorialHarness.named(app, "settings.accessMethod").tap()
		TutorialHarness.wait(TutorialHarness.named(app, "access.openRouter"), until: .hittable)
	}

	private func waitForChoice(_ app: XCUIApplication, openRouter: Bool) {
		TutorialHarness.wait(
			until: { TutorialHarness.named(app, "access.openRouter").isSelected == openRouter },
			message: "The saved OpenRouter mark did not update")
		assertChoice(app, openRouter: openRouter)
	}

	private func assertChoice(_ app: XCUIApplication, openRouter: Bool) {
		XCTAssertEqual(TutorialHarness.named(app, "access.openRouter").isSelected, openRouter)
		XCTAssertEqual(TutorialHarness.named(app, "access.credits").isSelected, !openRouter)
	}

	private var phrasebook: CatalogPhrasebook { CatalogPhrasebook(tag: .en) }

	private func capture(_ app: XCUIApplication, _ scenario: String) {
		let appearance = TutorialHarness.meanLuminance(app.screenshot()) < 0.4 ? "dark" : "light"
		TutorialHarness.attach(self, name: "openrouter-access-\(scenario)-\(appearance)", app: app)
	}
}
