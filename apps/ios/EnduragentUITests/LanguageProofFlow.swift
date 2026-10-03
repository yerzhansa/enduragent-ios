import EnduragentCoach
import XCTest

enum LanguagePickerEntry: String {
	case command
	case settings

	@MainActor
	func open(_ app: XCUIApplication) {
		switch self {
		case .command:
			TutorialHarness.send(app, "/language")
		case .settings:
			TutorialHarness.openSettings(app)
			let language = TutorialHarness.named(app, "settings.language")
			TutorialHarness.wait(language, until: .hittable)
			language.tap()
		}
		TutorialHarness.wait(TutorialHarness.named(app, "language.choice.automatic"))
	}

	@MainActor
	func close(_ app: XCUIApplication) {
		TutorialHarness.named(app, "language.close").tap()
		TutorialHarness.wait(TutorialHarness.named(app, "language.close"), until: .absent)
		if self == .settings { TutorialHarness.returnToChat(app) }
	}
}

enum LanguageProofFlow {
	@MainActor
	static func choose(_ app: XCUIApplication, _ id: String) {
		let choice = TutorialHarness.named(app, "language.choice.\(id)")
		TutorialHarness.wait(choice, until: .hittable)
		choice.tap()
		TutorialHarness.wait(
			until: { choice.isSelected }, message: "Language \(id) never became selected")
	}

	@MainActor
	static func assertReplyInstruction(
		_ app: XCUIApplication, language: LanguageTag, test: XCTestCase, name: String
	) {
		TutorialHarness.openDebug(app)
		XCTAssertEqual(TutorialHarness.debugRow(app, "fixture.requestCount").label, "0 requests")
		let instruction = TutorialHarness.debugRow(app, "fixture.replyLanguage")
		XCTAssertTrue(
			instruction.label.hasPrefix("Reply in \(language.englishName) (\(language.endonym))."),
			instruction.label)
		XCTAssertTrue(
			instruction.label.contains(
				"Write every athlete-facing sentence in \(language.englishName), even when the athlete writes in another language."
			), instruction.label)
		TutorialHarness.attach(test, name: name, app: app)
		TutorialHarness.returnToChat(app)
	}
}
