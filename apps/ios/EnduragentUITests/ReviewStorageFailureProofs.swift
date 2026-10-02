import XCTest

@MainActor
final class ReviewStorageFailureProof: XCTestCase {
	func testFailedAddSaveKeepsTheReviewAndExplainsTheChoiceWasNotSaved() {
		ReviewStorageFailureScreen.saveFailure(self, cancel: false, language: "en", dark: false)
	}

	func testFailedCancelSaveUsesTheChosenLanguage() {
		ReviewStorageFailureScreen.saveFailure(self, cancel: true, language: "fr", dark: false)
	}
}

@MainActor
final class ReviewStorageFailureDarkProof: XCTestCase {
	func testFailedAddSaveKeepsTheReviewAndExplainsTheChoiceWasNotSaved() {
		ReviewStorageFailureScreen.saveFailure(self, cancel: false, language: "en", dark: true)
	}

	func testFailedCancelSaveUsesTheChosenLanguage() {
		ReviewStorageFailureScreen.saveFailure(self, cancel: true, language: "fr", dark: true)
	}
}

@MainActor
enum ReviewStorageFailureScreen {
	static func saveFailure(_ test: XCTestCase, cancel: Bool, language: String, dark: Bool) {
		let app = XCUIApplication()
		TutorialHarness.launch(app)
		TutorialHarness.completeOnboarding(app)
		TutorialHarness.exchange(app, TutorialHarness.workout)
		ReviewRecoveryScreen.assertButtons(app, .approval, enabled: true)
		if language == "fr" {
			TutorialHarness.send(app, "/language")
			let french = TutorialHarness.named(app, "language.choice.fr")
			TutorialHarness.wait(french, until: .hittable)
			french.tap()
			TutorialHarness.wait(app.navigationBars["Choisis ta langue"])
			TutorialHarness.returnToChat(app)
			TutorialHarness.waitForLabel(app, "Vérification de la séance")
		}
		let calls = ReviewRecoveryScreen.calendarCalls(app)
		let requests = ReviewRecoveryScreen.modelRequests(app)
		TutorialHarness.fixtureControl(app, "fixture.failNextAppend")
		let action = TutorialHarness.named(app, cancel ? "chat.preview.cancel" : "chat.preview.add")
		TutorialHarness.wait(action, until: .enabled)
		action.tap()
		let sentence =
			language == "en"
			? "Couldn't save your choice on this iPhone, so nothing was changed. Try again."
			: "Impossible d’enregistrer votre choix sur cet iPhone. Rien n’a donc été modifié. Réessayez."
		TutorialHarness.waitForLabel(app, sentence)
		XCTAssertEqual(
			app.staticTexts.matching(NSPredicate(format: "label == %@", sentence)).count, 1)
		XCTAssertFalse(TutorialHarness.named(app, "chat.preview.notice").exists)
		XCTAssertTrue(TutorialHarness.named(app, "chat.preview.add").isEnabled)
		XCTAssertTrue(TutorialHarness.named(app, "chat.preview.cancel").isEnabled)
		XCTAssertFalse(app.staticTexts[TutorialHarness.done].exists)
		XCTAssertFalse(app.staticTexts["Sorry, something went wrong. Please try again."].exists)
		XCTAssertFalse(app.staticTexts["Désolé, une erreur s’est produite. Réessaie."].exists)
		XCTAssertEqual(ReviewRecoveryScreen.calendarCalls(app), calls)
		XCTAssertEqual(ReviewRecoveryScreen.modelRequests(app), requests)
		TutorialHarness.attach(
			test,
			name: "review-save-failed-" + (cancel ? "cancel-" : "add-") + (dark ? "dark" : "light"),
			app: app)
		let luminance = TutorialHarness.meanLuminance(app.screenshot())
		if dark { XCTAssertLessThan(luminance, 0.4) } else { XCTAssertGreaterThan(luminance, 0.4) }
		TutorialHarness.named(app, "chat.preview.cancel").tap()
		TutorialHarness.wait(TutorialHarness.named(app, "chat.preview.cancel"), until: .absent)
		TutorialHarness.wait(app.staticTexts[sentence], until: .absent)
		XCTAssertEqual(ReviewRecoveryScreen.calendarCalls(app), calls)
		XCTAssertEqual(ReviewRecoveryScreen.modelRequests(app), requests)
	}
}
