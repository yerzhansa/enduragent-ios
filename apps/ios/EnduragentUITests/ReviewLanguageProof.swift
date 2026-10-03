import XCTest

final class ReviewLanguageProof: XCTestCase {
	func testReviewAndSavedOutcomeFollowTheChosenLanguage() {
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
		TutorialHarness.waitForLabel(app, "Vérification de la séance")
		TutorialHarness.waitForLabel(app, "Échauffement")
		TutorialHarness.waitForLabel(app, "Bloc principal")
		let add = TutorialHarness.named(app, "chat.preview.add")
		TutorialHarness.wait(add, until: .enabled)
		XCTAssertEqual(add.label, "Ajouter au calendrier")
		XCTAssertEqual(TutorialHarness.named(app, "chat.preview.cancel").label, "Annuler")
		TutorialHarness.attach(self, name: "review-french", app: app)
		add.tap()
		let done = "C’est fait — Créer l’entraînement « Endurance with tempo » le 6/16/1998."
		TutorialHarness.waitForLabel(app, done)
		TutorialHarness.relaunchKeepingStore(app)
		TutorialHarness.waitForLabel(app, done)
		TutorialHarness.attach(self, name: "review-french-relaunch", app: app)
	}
}
