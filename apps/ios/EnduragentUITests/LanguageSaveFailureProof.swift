import XCTest

@MainActor
final class LanguageSaveFailureProof: XCTestCase {
	func testFailuresFromCommand() {
		proveFailures(from: .command)
	}

	func testFailuresFromSettings() {
		proveFailures(from: .settings)
	}

	private func proveFailures(from entry: LanguagePickerEntry) {
		let app = XCUIApplication()
		TutorialHarness.launch(app, language: "ru,fr,en", locale: "fr_FR")
		TutorialHarness.completeOnboarding(app, language: .fr)
		entry.open(app)
		LanguageProofFlow.choose(app, "en")
		entry.close(app)
		for attempted in ["de", "automatic"] {
			TutorialHarness.fixtureControl(app, "fixture.failNextAppend")
			entry.open(app)
			TutorialHarness.named(app, "language.choice.\(attempted)").tap()
			let notice = TutorialHarness.named(app, "language.saveFailed")
			TutorialHarness.wait(notice)
			XCTAssertEqual(
				notice.label,
				"Couldn't save your choice on this iPhone, so nothing was changed. Try again.")
			XCTAssertTrue(TutorialHarness.named(app, "language.choice.en").isSelected)
			XCTAssertFalse(TutorialHarness.named(app, "language.choice.\(attempted)").isSelected)
			XCTAssertTrue(app.navigationBars["Choose your language"].exists)
			TutorialHarness.attach(
				self, name: "u9-2-\(entry.rawValue)-failed-\(attempted)", app: app)
			entry.close(app)
			TutorialHarness.exchange(app, TutorialHarness.weekQuestion)
			LanguageProofFlow.assertReplyInstruction(
				app, prefix: "The athlete chose English (English).", test: self,
				name: "u9-2-\(entry.rawValue)-failed-\(attempted)-instruction")
			entry.open(app)
			XCTAssertFalse(TutorialHarness.named(app, "language.saveFailed").exists)
			entry.close(app)
			TutorialHarness.relaunchKeepingStore(app)
			TutorialHarness.wait(app.navigationBars["Chat"])
			XCTAssertEqual(
				TutorialHarness.named(app, "chat.composer").placeholderValue, "Message your coach")
			entry.open(app)
			XCTAssertTrue(TutorialHarness.named(app, "language.choice.en").isSelected)
			XCTAssertFalse(TutorialHarness.named(app, "language.choice.\(attempted)").isSelected)
			TutorialHarness.attach(
				self, name: "u9-2-\(entry.rawValue)-failed-\(attempted)-restored", app: app)
			entry.close(app)
			TutorialHarness.exchange(app, "How should I pace an easy ride?")
			LanguageProofFlow.assertReplyInstruction(
				app, prefix: "The athlete chose English (English).", test: self,
				name: "u9-2-\(entry.rawValue)-failed-\(attempted)-restored-instruction")
		}
	}
}
