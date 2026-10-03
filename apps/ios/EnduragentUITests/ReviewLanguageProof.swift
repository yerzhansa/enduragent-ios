import XCTest

final class ReviewLanguageProof: XCTestCase {
	func testReviewAndSavedOutcomeFollowTheChosenLanguage() {
		ReviewLanguageProofScreen.prove(self, dark: false)
	}
}

final class ReviewLanguageDarkProof: XCTestCase {
	func testReviewAndSavedOutcomeFollowTheChosenLanguage() {
		ReviewLanguageProofScreen.prove(self, dark: true)
	}
}

private enum ReviewLanguageProofScreen {
	static func prove(_ test: XCTestCase, dark: Bool) {
		let app = XCUIApplication()
		TutorialHarness.launch(app)
		TutorialHarness.completeOnboarding(app)
		TutorialHarness.exchange(app, TutorialHarness.workout)
		TutorialHarness.wait(TutorialHarness.named(app, "chat.preview.add"), until: .enabled)
		TutorialHarness.send(app, "/language")
		let french = TutorialHarness.named(app, "language.choice.fr")
		TutorialHarness.wait(french)
		french.tap()
		TutorialHarness.wait(app.navigationBars["Choisis ta langue"])
		TutorialHarness.named(app, "language.close").tap()
		TutorialHarness.relaunchKeepingStore(app, language: "en", locale: "fr_FR")
		TutorialHarness.waitForLabel(app, "Vérification de la séance")
		let card = TutorialHarness.text(app, containing: "Warmup ramp 1.5")
		TutorialHarness.wait(card)
		XCTAssertEqual(
			card.label,
			[
				"Échauffement", "- 10m 55-65%", "", "Bloc principal",
				"- 10m progressif 60,5-80,5% 90rpm Warmup ramp 1.5", "2x",
				"- 10m 190,5-225,5w 85-95rpm", "- 5m Z1-Z2", "", "Retour au calme", "- 10m 55-65%",
			].joined(separator: "\n"))
		XCTAssertFalse(card.label.contains("{\""))
		let add = TutorialHarness.named(app, "chat.preview.add")
		TutorialHarness.wait(add, until: .enabled)
		XCTAssertEqual(add.label, "Ajouter au calendrier")
		XCTAssertEqual(TutorialHarness.named(app, "chat.preview.cancel").label, "Annuler")
		let luminance = TutorialHarness.meanLuminance(app.screenshot())
		if dark {
			XCTAssertLessThan(luminance, 0.4, "The reopened review is not in dark appearance")
		} else {
			XCTAssertGreaterThan(luminance, 0.4, "The reopened review is not in light appearance")
		}
		let theme = dark ? "dark" : "light"
		TutorialHarness.attach(test, name: "u9-4-review-reopened-fr-\(theme)", app: app)
		add.tap()
		let done = "C’est fait — Créer l’entraînement « Endurance with tempo » le 16/06/1998."
		TutorialHarness.waitForIdentifier(app, "chat.note", reading: done)
		TutorialHarness.relaunchKeepingStore(app)
		TutorialHarness.waitForIdentifier(app, "chat.note", reading: done)
		TutorialHarness.attach(test, name: "u9-4-outcome-reopened-fr-\(theme)", app: app)
		TutorialHarness.send(app, "/language")
		let english = TutorialHarness.named(app, "language.choice.en")
		TutorialHarness.wait(english)
		english.tap()
		TutorialHarness.named(app, "language.close").tap()
		let englishDone = "Done — Create workout \"Endurance with tempo\" on 16/06/1998."
		TutorialHarness.waitForIdentifier(app, "chat.note", reading: englishDone)
		TutorialHarness.startNewConversation(app)
		TutorialHarness.openHistory(app)
		let row = TutorialHarness.historyRows(app).firstMatch
		TutorialHarness.wait(row, until: .hittable)
		row.tap()
		let archive = TutorialHarness.named(app, "archive.content")
		TutorialHarness.wait(archive)
		let outcome = archive.descendants(matching: .any).matching(identifier: "archive.note")
			.firstMatch
		TutorialHarness.wait(outcome)
		XCTAssertEqual(outcome.label, englishDone)
		TutorialHarness.attach(test, name: "u9-4-history-outcome-en-\(theme)", app: app)
		TutorialHarness.returnToChat(app)
		TutorialHarness.assertZeroFixtureRequests(app)
	}
}
