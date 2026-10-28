import EnduragentCoach
import XCTest

@MainActor
final class SessionSettingsLargestTextProof: XCTestCase {
	func testFieldsStackAndSaveCancelAreWhole() { SessionLargestText.fieldsStack(self, .en) }
	func testReadingOrder() { SessionLargestText.readingOrder(self, .en) }
}

@MainActor
final class SessionSettingsLargestTextDeProof: XCTestCase {
	func testFieldsStackAndSaveCancelAreWhole() { SessionLargestText.fieldsStack(self, .de) }
	func testReadingOrder() { SessionLargestText.readingOrder(self, .de) }
}

@MainActor
private enum SessionLargestText {
	static let fields: [(name: String, label: CatalogKey)] = [
		("historyBudgetRatio", Catalog.settingsConversationFieldsHistoryTokenBudgetRatioLabel),
		("contextWindowOverride", Catalog.settingsSessionContextWindowLabel),
	]

	static func fieldsStack(_ test: XCTestCase, _ language: LanguageTag) {
		let run = open(test, language)
		let app = run.app
		let window = LargestTextScreen.window(app)
		for field in fields {
			let label = run.named("session.\(field.name).label")
			let input = run.named("session.\(field.name).input")
			let unit = run.named("session.\(field.name).unit")
			LargestTextScreen.reveal(app, input, tappable: true)
			XCTAssertEqual(label.label, run.say(field.label), field.name)
			XCTAssertGreaterThanOrEqual(input.frame.minY, label.frame.maxY - 2, field.name)
			XCTAssertEqual(input.frame.minX, label.frame.minX, accuracy: 2, field.name)
			let beside = unit.frame.minY < input.frame.maxY - 2
			if beside {
				XCTAssertGreaterThanOrEqual(unit.frame.minX, input.frame.maxX - 2, field.name)
			} else {
				XCTAssertGreaterThanOrEqual(unit.frame.minY, input.frame.maxY - 2, field.name)
			}
			let spanned = beside ? unit.frame.maxX - input.frame.minX : input.frame.width
			XCTAssertGreaterThanOrEqual(
				spanned, window.width * LargestTextScreen.wholeRowShare,
				"\(field.name) is not full width")
		}
		attach(test, language, "fields", app)
		LargestTextScreen.toTop(app)
		enter(app, "historyBudgetRatio", "0")
		let save = run.named("session.save")
		LargestTextScreen.reveal(app, save, tappable: true)
		XCTAssertEqual(save.label, run.say(Catalog.commonSave))
		LargestTextScreen.assertWhole(app, save)
		save.tap()
		LargestTextScreen.toTop(app)
		let rejection = SupportScreen.outcome(
			app, "session.historyBudgetRatio.rejection",
			run.say(Catalog.settingsConversationValidationHistoryTokenBudgetRatio))
		LargestTextScreen.reveal(app, rejection, tappable: false)
		let input = run.named("session.historyBudgetRatio.input")
		let unit = run.named("session.historyBudgetRatio.unit")
		XCTAssertGreaterThanOrEqual(
			rejection.frame.minY, max(input.frame.maxY, unit.frame.maxY) - 2,
			"the rejection is not under its field")
		attach(test, language, "rejected", app)
		let cancel = run.named("session.cancel")
		LargestTextScreen.reveal(app, cancel, tappable: true)
		XCTAssertEqual(cancel.label, run.say(Catalog.commonCancel))
		LargestTextScreen.assertWhole(app, cancel)
		attach(test, language, "save-cancel", app)
		cancel.tap()
		TutorialHarness.wait(cancel, until: .absent)
		XCTAssertFalse(rejection.exists)
	}

	static func readingOrder(_ test: XCTestCase, _ language: LanguageTag) {
		let run = open(test, language)
		let app = run.app
		enter(app, "historyBudgetRatio", "5")
		LargestTextScreen.reveal(app, run.named("session.save"), tappable: false)
		LargestTextScreen.toTop(app)
		let parts = ["label", "input", "unit", "help"]
		let order =
			fields.flatMap { field in parts.map { "session.\(field.name).\($0)" } }
			+ ["session.save", "session.cancel"]
		LargestTextScreen.expectOrder(app, order, screen: "[\(language.rawValue)] Session")
		attach(test, language, "reading-order", app)
	}

	private static func open(_ test: XCTestCase, _ language: LanguageTag) -> MatrixRun {
		let run = LargestTextScreen.begin(test, language)
		LargestTextScreen.open(
			run.app, row: "settings.session", showing: "session.historyBudgetRatio.input")
		return run
	}

	private static func enter(_ app: XCUIApplication, _ field: String, _ value: String) {
		let input = TutorialHarness.named(app, "session.\(field).input")
		LargestTextScreen.reveal(app, input, tappable: true)
		let shown = input.value as? String ?? ""
		input.coordinate(withNormalizedOffset: CGVector(dx: 0.99, dy: 0.5)).tap()
		input.typeText(
			String(repeating: XCUIKeyboardKey.delete.rawValue, count: shown.count) + value)
		TutorialHarness.wait(input, until: .value(value))
		input.typeText("\n")
	}

	private static func attach(
		_ test: XCTestCase, _ language: LanguageTag, _ screen: String, _ app: XCUIApplication
	) {
		TutorialHarness.attach(
			test, name: "largest-\(language.rawValue)-session-\(screen)-light", app: app)
	}
}
