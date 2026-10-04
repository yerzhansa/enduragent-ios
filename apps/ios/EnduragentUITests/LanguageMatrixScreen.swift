import EnduragentCoach
import EnduragentCoachFixtures
import XCTest

@MainActor
struct MatrixRun {
	let test: XCTestCase
	let app: XCUIApplication
	let language: LanguageTag

	static func begin(
		_ test: XCTestCase, _ language: LanguageTag,
		arguments: FixtureArguments = FixtureArguments(), connected: Bool = true
	) -> MatrixRun {
		let app = XCUIApplication()
		TutorialHarness.launch(app, arguments: arguments)
		if arguments.onboarded {
			TutorialHarness.agreeToProviderConsent(app)
		} else if connected {
			TutorialHarness.completeOnboarding(app)
		} else {
			TutorialHarness.startUnconnected(app)
		}
		let run = MatrixRun(test: test, app: app, language: language)
		run.chooseLanguage()
		return run
	}

	func say(_ key: CatalogKey, count: Int? = nil, _ vars: [String: String] = [:]) -> String {
		CatalogPhrasebook(tag: language).say(key, count: count, vars)
	}

	func named(_ identifier: String) -> XCUIElement {
		TutorialHarness.named(app, identifier)
	}

	func tap(_ identifier: String) {
		let control = named(identifier)
		TutorialHarness.wait(control, until: .hittable)
		control.tap()
	}

	func expect(_ identifier: String, _ key: CatalogKey, _ vars: [String: String] = [:]) {
		expect(identifier, matching: "label == %@", say(key, vars))
	}

	func expect(_ identifier: String, contains key: CatalogKey) {
		expect(identifier, matching: "label CONTAINS %@", say(key))
	}

	func expectText(_ key: CatalogKey, _ vars: [String: String] = [:]) {
		expectShown(app.staticTexts[say(key, vars)], key)
	}

	func expectTitle(_ key: CatalogKey) {
		expectShown(app.navigationBars[say(key)], key)
	}

	func expectNotice(_ key: CatalogKey) {
		expect("chat.turn.notice", key)
	}

	func expectChrome() {
		expectOwnPlaceholder()
		expect("chat.history", Catalog.archiveHistory)
		expect("chat.settings", Catalog.settingsTitle)
		expect("chat.newConversation", Catalog.chatNewConversationLabel)
		expect("chat.send", Catalog.chatComposerSend)
		expectText(Catalog.chatViewDisclaimer)
		expectTitle(Catalog.chatViewTitle)
	}

	func openSettingsRow(_ identifier: String) {
		TutorialHarness.openSettings(app)
		tap(identifier)
	}

	func screen(_ name: String) {
		let title = "u9-5b-\(language.rawValue)-\(name)"
		TutorialHarness.attach(test, name: title, app: app)
		do {
			let shown = MatrixSweep.shown(in: try app.snapshot())
			let strings = XCTAttachment(string: shown.joined(separator: "\n"))
			strings.name = "\(title)-strings"
			strings.lifetime = .keepAlways
			test.add(strings)
			XCTAssertFalse(shown.isEmpty, "\(title) shows no text")
			let findings = MatrixSweep.findings(
				in: shown, catalog: try MatrixCatalog.load(language))
			XCTAssertTrue(findings.isEmpty, "\(title): \(findings.joined(separator: "; "))")
		} catch {
			XCTFail("\(title): the screen could not be read: \(error)")
		}
	}

	private func chooseLanguage() {
		LanguagePickerEntry.settings.open(app)
		let choice = named("language.choice.\(language.rawValue)")
		for _ in 0..<4 where !(choice.exists && choice.isHittable) {
			app.swipeUp(velocity: .slow)
		}
		LanguageProofFlow.choose(app, language.rawValue)
		expectTitle(Catalog.languageChooseTitle)
		LanguagePickerEntry.settings.close(app)
		expectOwnPlaceholder()
	}

	private func expectOwnPlaceholder() {
		let key = Catalog.chatComposerMessagePlaceholder
		XCTAssertEqual(named("chat.composer").placeholderValue, say(key), language.rawValue)
		if let sibling = language.regionalSibling {
			XCTAssertNotEqual(say(key), CatalogPhrasebook(tag: sibling).say(key))
		}
	}

	private func expect(_ identifier: String, matching format: String, _ expected: String) {
		let match = app.descendants(matching: .any).matching(
			NSPredicate(format: "identifier == %@ AND \(format)", identifier, expected)
		).firstMatch
		if TutorialHarness.wait(match, required: false) { return }
		let shown = app.descendants(matching: .any).matching(identifier: identifier)
			.allElementsBoundByIndex.map(\.label)
		XCTFail("[\(language.rawValue)] \(identifier) shows \(shown), expected \(expected)")
	}

	private func expectShown(_ element: XCUIElement, _ key: CatalogKey) {
		if TutorialHarness.wait(element, required: false) { return }
		XCTFail("[\(language.rawValue)] \(key.rawValue) is not shown as \(say(key))")
	}
}

@MainActor
enum MatrixSweep {
	static let messages = [
		TutorialHarness.weekQuestion, TutorialHarness.workout, TutorialHarness.draft,
		"Read the connected athlete's week", "fixture:text-then-hang", "fixture:fail 402",
		"fixture:fail 400", "fixture:fail 403", "/language",
	]

	private static let unswept = [
		"fixture.", "debug.", "settings.debug", "chat.turnProgress", "chat.toolProgress",
		"consent.modelRequestCount", "reply.",
	]

	private static let data =
		messages + LanguageTag.allCases.map(\.endonym) + [
			AthleteOwnershipFixture.savedQuestion, AthleteOwnershipFixture.unknownQuestion,
			"Ada Kovač", "Bo Lind", "Endurance with tempo", "Warmup ramp 1.5",
			"DeepSeek V4.1 Flash", "DeepSeek",
		]

	static func shown(in screen: any XCUIElementSnapshot) -> [String] {
		var texts: [String] = []
		collect(screen, inBar: false, into: &texts)
		var seen = Set<String>()
		return texts.filter { !$0.isEmpty && seen.insert($0).inserted }
	}

	static func findings(in shown: [String], catalog: MatrixCatalog) -> [String] {
		var findings: [String] = []
		for text in shown {
			if catalog.hasUnresolvedPlaceholder(text) {
				findings.append("unresolved placeholder in \"\(text)\"")
			}
			for part in parts(of: text) {
				if catalog.keys.contains(part) {
					findings.append("raw key \"\(part)\"")
				} else if catalog.isEnglishFallback(part) {
					findings.append("English fallback \"\(part)\"")
				}
			}
		}
		return findings
	}

	private static func parts(of text: String) -> [String] {
		var copy = text
		for datum in data { copy = copy.replacingOccurrences(of: datum, with: "§") }
		let lines = copy.components(separatedBy: "\n")
		let phrases = lines.flatMap { $0.components(separatedBy: ", ") }
		var seen = Set<String>()
		return ([copy] + lines + phrases)
			.map { $0.trimmingCharacters(in: .whitespaces) }
			.filter { $0.contains(where: \.isLetter) && seen.insert($0).inserted }
	}

	private static func collect(
		_ node: any XCUIElementSnapshot, inBar: Bool, into texts: inout [String]
	) {
		if node.elementType == .keyboard { return }
		if unswept.contains(where: { node.identifier.hasPrefix($0) }) { return }
		switch node.elementType {
		case .staticText:
			texts.append(node.label)
		case .button:
			if inBar && node.identifier.isEmpty { return }
			texts.append(node.label)
		case .textField, .secureTextField:
			texts.append(node.label)
			texts.append(node.placeholderValue ?? "")
		default:
			break
		}
		for child in node.children {
			collect(child, inBar: inBar || node.elementType == .navigationBar, into: &texts)
		}
	}
}

extension LanguageTag {
	fileprivate var regionalSibling: LanguageTag? {
		switch self {
		case .ptPT: .ptBR
		case .ptBR: .ptPT
		case .zhHans: .zhHant
		case .zhHant: .zhHans
		default: nil
		}
	}
}
