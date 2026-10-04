import EnduragentCoach
import XCTest

@MainActor
final class OpenRouterRecoveryProof: XCTestCase {
	func testMissingKeyChoosesAccessWithoutSignIn() {
		let app = launch(.missingOpenRouter)
		TutorialHarness.exchange(app, "Missing OpenRouter connection")
		TutorialHarness.waitForIdentifier(
			app, "chat.turn.notice", reading: TutorialHarness.notConfigured)
		XCTAssertFalse(TutorialHarness.named(app, "chat.access.signInAgain").exists)
		XCTAssertFalse(TutorialHarness.named(app, "chat.turn.signInAgain").exists)
		capture(app, "missing-key")
		TutorialHarness.named(app, "chat.turn.chooseAccessMethod").tap()
		TutorialHarness.wait(TutorialHarness.named(app, "access.openRouter"))
		XCTAssertTrue(TutorialHarness.named(app, "access.openRouter").isSelected)
		capture(app, "missing-key-access")
		TutorialHarness.returnToChat(app)
		assertModelRequests(app, 0)
	}

	func testRejectedKeySurvivesRelaunchAndDirectSignInKeepsConversation() {
		let app = launch(.rejectedOpenRouter, signIn: .held)
		let question = "Keep this rejected question"
		TutorialHarness.exchange(app, question)
		assertRecovery(app)
		capture(app, "rejected-key")
		assertModelRequests(app, 1)
		TutorialHarness.relaunchKeepingStore(app)
		TutorialHarness.wait(TutorialHarness.named(app, "chat.composer"))
		assertRecovery(app)
		TutorialHarness.exchange(app, "Further turns stay blocked")
		assertRecovery(app)
		capture(app, "rejected-key-reopened")
		assertModelRequests(app, 0)
		TutorialHarness.named(app, "chat.access.signInAgain").tap()
		TutorialHarness.waitForIdentifier(app, "fixture.signInCount", reading: "1 authorizations")
		XCTAssertFalse(TutorialHarness.named(app, "chat.access.signInAgain").isEnabled)
		capture(app, "direct-sign-in")
		TutorialHarness.named(app, "fixture.completeSignIn").tap()
		TutorialHarness.wait(
			until: { !TutorialHarness.named(app, "chat.access.signInAgain").exists },
			message: "Sign-in did not clear the recovery prompt")
		XCTAssertFalse(TutorialHarness.named(app, "access.openRouter").exists)
		TutorialHarness.exchange(app, "Recovered in the same conversation")
		TutorialHarness.waitForLabel(app, TutorialHarness.weekReply)
		capture(app, "recovered-conversation")
		TutorialHarness.relaunchKeepingStore(app)
		TutorialHarness.waitForLabel(app, TutorialHarness.weekReply)
		XCTAssertFalse(TutorialHarness.named(app, "chat.access.signInAgain").exists)
		TutorialHarness.named(app, "chat.transcript").swipeDown()
		TutorialHarness.waitForLabel(app, question)
		capture(app, "recovered-reopened")
		TutorialHarness.assertZeroFixtureRequests(app)
	}

	func testTwoOverlappingRejectionsShowOnePrompt() {
		let app = launch(.openRouter, signIn: .success)
		TutorialHarness.fixtureControl(app, "fixture.rejectTwoRequests")
		TutorialHarness.returnToChat(app)
		assertRecovery(app)
		capture(app, "two-rejections-one-prompt")
		assertModelRequests(app, 2)
		TutorialHarness.named(app, "chat.access.signInAgain").tap()
		TutorialHarness.wait(
			until: { !TutorialHarness.named(app, "chat.access.signInAgain").exists },
			message: "Recovery did not clear the prompt")
		TutorialHarness.exchange(app, "Recovered overlapping requests")
		TutorialHarness.waitForLabel(app, TutorialHarness.weekReply)
		capture(app, "two-rejections-recovered")
		TutorialHarness.assertZeroFixtureRequests(app)
	}

	func testForbiddenRequestKeepsTheKeyAndHasNoSignIn() {
		let app = launch(.openRouter)
		TutorialHarness.exchange(app, "fixture:fail 403")
		TutorialHarness.waitForIdentifier(
			app, "chat.turn.notice",
			reading: "OpenRouter blocked this request. Try a different model or message.")
		XCTAssertFalse(TutorialHarness.named(app, "chat.access.signInAgain").exists)
		XCTAssertFalse(TutorialHarness.named(app, "chat.turn.signInAgain").exists)
		XCTAssertFalse(TutorialHarness.named(app, "chat.turn.tryAgain").exists)
		capture(app, "forbidden-request")
		assertModelRequests(app, 1)
		TutorialHarness.exchange(app, "A different message")
		TutorialHarness.waitForLabel(app, TutorialHarness.weekReply)
		capture(app, "forbidden-key-still-works")
		TutorialHarness.assertZeroFixtureRequests(app)
	}

	private func launch(_ access: FixtureAccessMethod, signIn: FixtureSignInOutcome = .cancel)
		-> XCUIApplication
	{
		let app = XCUIApplication()
		TutorialHarness.launch(
			app,
			arguments: FixtureArguments(
				onboarded: true, accessMethod: access, signInOutcome: signIn))
		TutorialHarness.agreeToProviderConsent(
			app, recipient: (model: "fixture/openrouter-model", provider: "Fixture Host"))
		return app
	}

	private func assertRecovery(_ app: XCUIApplication) {
		TutorialHarness.wait(
			TutorialHarness.named(app, "chat.access.signInAgain"), until: .hittable)
		let transcript = TutorialHarness.named(app, "chat.transcript")
		XCTAssertEqual(
			transcript.staticTexts.matching(
				NSPredicate(
					format: "label == %@",
					"Your OpenRouter sign-in is no longer valid. Sign in again to continue.")
			).count, 1)
		XCTAssertEqual(transcript.buttons.matching(identifier: "chat.access.signInAgain").count, 1)
		XCTAssertEqual(TutorialHarness.named(app, "chat.access.signInAgain").label, "Sign in again")
		XCTAssertFalse(
			transcript.buttons.matching(identifier: "chat.turn.signInAgain").firstMatch.exists)
	}

	private func assertModelRequests(_ app: XCUIApplication, _ count: Int) {
		TutorialHarness.openDebug(app)
		XCTAssertEqual(
			TutorialHarness.debugRow(app, "fixture.modelRequestCount").label,
			"\(count) model requests")
		TutorialHarness.returnToChat(app)
	}

	private func capture(_ app: XCUIApplication, _ scenario: String) {
		let appearance = TutorialHarness.meanLuminance(app.screenshot()) < 0.4 ? "dark" : "light"
		TutorialHarness.attach(
			self, name: "openrouter-recovery-\(scenario)-\(appearance)", app: app)
	}
}
