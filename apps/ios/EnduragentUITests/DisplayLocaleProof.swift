import EnduragentCoach
import XCTest

@MainActor
final class DisplayLocaleProof: XCTestCase {
	func testFrenchWordsWithUSFormats() {
		prove(
			region: "en_US", history: "mercredi, mars 4, 2026", pack: "2,000 crédits",
			outcomeDate: "6/16/1998")
	}

	func testFrenchWordsWithFrenchFormats() {
		prove(
			region: "fr_FR", history: "mercredi 4 mars 2026", pack: "2 000 crédits",
			outcomeDate: "16/06/1998")
	}

	private func prove(region: String, history: String, pack: String, outcomeDate: String) {
		let app = XCUIApplication()
		TutorialHarness.launch(
			app, language: "ru,fr,en", locale: region, clock: "1998-06-15T13:05:00Z")
		TutorialHarness.completeOnboarding(app, language: .fr) {
			TutorialHarness.attach(self, name: "u9-3-setup-fr-\(region)", app: app)
		}
		TutorialHarness.relaunchKeepingStore(app, clock: "2026-03-04T13:05:00Z")
		TutorialHarness.exchange(app, TutorialHarness.weekQuestion)
		TutorialHarness.startNewConversation(app, language: .fr)
		TutorialHarness.openHistory(app)
		let date = app.staticTexts.matching(
			NSPredicate(format: "identifier BEGINSWITH %@", "history.date.")
		).firstMatch
		TutorialHarness.wait(date)
		XCTAssertEqual(date.label, history)
		TutorialHarness.attach(self, name: "u9-3-history-fr-\(region)", app: app)
		TutorialHarness.returnToChat(app)
		TutorialHarness.openSettings(app)
		let credits = TutorialHarness.named(app, "settings.credits")
		TutorialHarness.wait(credits, until: .hittable)
		credits.tap()
		let large = TutorialHarness.named(app, "credits.pack.icu.enduragent.credits.large")
		TutorialHarness.wait(large)
		XCTAssertEqual(large.label, pack)
		TutorialHarness.attach(self, name: "u9-3-credits-fr-\(region)", app: app)
		TutorialHarness.returnToChat(app)
		TutorialHarness.relaunchKeepingStore(app, clock: "1998-06-15T13:05:00Z")
		TutorialHarness.exchange(app, TutorialHarness.workout)
		let add = TutorialHarness.named(app, "chat.preview.add")
		TutorialHarness.wait(add, until: .enabled)
		add.tap()
		let note = TutorialHarness.named(app, "chat.note")
		TutorialHarness.wait(note)
		XCTAssertTrue(note.label.contains(outcomeDate), note.label)
		XCTAssertTrue(note.label.contains("Endurance with tempo"), note.label)
		TutorialHarness.attach(self, name: "u9-3-review-notice-fr-\(region)", app: app)
		TutorialHarness.send(app, "/language")
		let english = TutorialHarness.named(app, "language.choice.en")
		TutorialHarness.wait(english)
		english.tap()
		TutorialHarness.named(app, "language.close").tap()
		TutorialHarness.wait(app.navigationBars["Chat"])
		TutorialHarness.wait(note)
		XCTAssertTrue(note.label.contains(outcomeDate), note.label)
		XCTAssertTrue(note.label.hasPrefix("Done"), note.label)
		TutorialHarness.attach(self, name: "u9-3-review-notice-en-\(region)", app: app)
	}
}
