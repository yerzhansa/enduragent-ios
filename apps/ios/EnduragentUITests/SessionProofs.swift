import EnduragentCoach
import XCTest

@MainActor
final class LanguagePickerProof: XCTestCase {
	private let english = [
		"Automatic", "English", "Español", "Français", "Italiano", "Deutsch", "Nederlands",
		"Dansk", "Svenska", "Norsk bokmål", "Suomi", "Português (Portugal)",
		"Português (Brasil)", "Polski", "한국어", "日本語", "简体中文", "繁體中文",
	]

	func testLanguagePickerFromCommand() {
		proveLanguagePicker(from: .command)
	}

	func testLanguagePickerFromSettings() {
		proveLanguagePicker(from: .settings)
	}

	private func proveLanguagePicker(from entry: LanguagePickerEntry) {
		let app = XCUIApplication()
		TutorialHarness.launch(app)
		TutorialHarness.completeOnboarding(app)
		TutorialHarness.wait(app.navigationBars["Chat"])
		entry.open(app)
		let automatic = TutorialHarness.named(app, "language.choice.automatic")
		TutorialHarness.wait(automatic)
		XCTAssertTrue(app.buttons["Sheet Grabber"].exists)
		XCTAssertTrue(app.navigationBars["Choose your language"].exists)
		XCTAssertGreaterThan(
			app.navigationBars["Choose your language"].frame.minY,
			app.windows.firstMatch.frame.height * 0.1)
		XCTAssertTrue(automatic.isSelected)
		let visible = choiceLabels(app)
		XCTAssertGreaterThanOrEqual(visible.count, 10)
		XCTAssertEqual(visible, Array(english.prefix(visible.count)))
		TutorialHarness.attach(self, name: "u9-2-\(entry.rawValue)-picker-auto", app: app)
		let french = TutorialHarness.named(app, "language.choice.fr")
		let switched = timedChoice(french, until: app.navigationBars["Choisis ta langue"])
		XCTAssertTrue(french.isSelected)
		XCTAssertFalse(automatic.isSelected)
		TutorialHarness.attach(self, name: "u9-2-\(entry.rawValue)-picker-fr", app: app)
		let unchanged = timedChoice(french, until: app.navigationBars["Choisis ta langue"])
		XCTAssertTrue(french.isSelected)
		record(switched: switched, unchanged: unchanged)
		XCTAssertEqual(scrolledChoiceLabels(app), ["Automatique"] + english.dropFirst())
		entry.close(app)
		TutorialHarness.relaunchKeepingStore(app)
		TutorialHarness.wait(app.navigationBars["Conversation"])
		entry.open(app)
		XCTAssertTrue(TutorialHarness.named(app, "language.choice.fr").isSelected)
		XCTAssertFalse(TutorialHarness.named(app, "language.choice.automatic").isSelected)
		TutorialHarness.attach(self, name: "u9-2-\(entry.rawValue)-fixed-restored", app: app)
		entry.close(app)
		XCTAssertEqual(
			TutorialHarness.named(app, "chat.composer").placeholderValue, "Écris à ton coach")
		TutorialHarness.exchange(app, TutorialHarness.weekQuestion)
		LanguageProofFlow.assertReplyInstruction(
			app, language: .fr, test: self,
			name: "u9-2-\(entry.rawValue)-fixed-english-instruction")
		TutorialHarness.attach(self, name: "u9-2-\(entry.rawValue)-fixed-english", app: app)
		TutorialHarness.relaunchKeepingStore(app)
		TutorialHarness.wait(app.navigationBars["Conversation"])
		TutorialHarness.openRecords(app)
		XCTAssertEqual(
			TutorialHarness.recordCount(app, "languagePreference"), "languagePreference 1")
		TutorialHarness.returnToChat(app)
		TutorialHarness.attach(self, name: "u9-2-\(entry.rawValue)-fixed-survives", app: app)
	}

	private func choiceLabels(_ app: XCUIApplication) -> [String] {
		app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "language.choice."))
			.allElementsBoundByIndex.filter { $0.isHittable }.map { $0.label }
	}

	private func scrolledChoiceLabels(_ app: XCUIApplication) -> [String] {
		var labels: [String] = []
		var selected = Set<String>()
		for _ in 0..<4 {
			let choices = app.buttons.matching(
				NSPredicate(format: "identifier BEGINSWITH %@", "language.choice."))
			for choice in choices.allElementsBoundByIndex
			where choice.isHittable && choice.isSelected {
				selected.insert(choice.identifier)
			}
			for label in choiceLabels(app) where !labels.contains(label) {
				labels.append(label)
			}
			app.swipeUp(velocity: .slow)
		}
		XCTAssertEqual(selected, ["language.choice.fr"])
		return labels
	}

	private func timedChoice(_ choice: XCUIElement, until title: XCUIElement) -> TimeInterval {
		let tapped = Date()
		choice.tap()
		TutorialHarness.wait(title, within: .screen)
		return Date().timeIntervalSince(tapped)
	}

	private func record(switched: TimeInterval, unchanged: TimeInterval) {
		let metric = XCTAttachment(
			string: String(
				format: "languageSwitchSeconds %.3f sameLanguageSeconds %.3f", switched, unchanged))
		metric.name = "language-switch-seconds"
		metric.lifetime = .keepAlways
		add(metric)
	}
}

@MainActor
final class AutomaticFrenchPhoneProof: XCTestCase {
	func testAutomaticFromCommand() {
		proveAutomatic(from: .command)
	}

	func testAutomaticFromSettings() {
		proveAutomatic(from: .settings)
	}

	private func proveAutomatic(from entry: LanguagePickerEntry) {
		let app = XCUIApplication()
		app.launchEnvironment["ENDURAGENT_LANGUAGE"] = "de"
		TutorialHarness.launch(app, language: "ru,fr,en", locale: "fr_FR")
		TutorialHarness.completeOnboarding(app, language: .fr)
		TutorialHarness.wait(app.navigationBars["Conversation"])
		XCTAssertEqual(
			TutorialHarness.named(app, "chat.composer").placeholderValue, "Écris à ton coach")
		entry.open(app)
		LanguageProofFlow.choose(app, "en")
		entry.close(app)
		TutorialHarness.wait(app.navigationBars["Chat"])
		entry.open(app)
		LanguageProofFlow.choose(app, "automatic")
		let automatic = TutorialHarness.named(app, "language.choice.automatic")
		TutorialHarness.wait(automatic)
		XCTAssertTrue(automatic.isSelected)
		XCTAssertEqual(automatic.label, "Automatique")
		TutorialHarness.attach(self, name: "u9-2-\(entry.rawValue)-automatic-selected", app: app)
		entry.close(app)
		TutorialHarness.relaunchKeepingStore(app)
		TutorialHarness.wait(app.navigationBars["Conversation"])
		entry.open(app)
		XCTAssertTrue(TutorialHarness.named(app, "language.choice.automatic").isSelected)
		XCTAssertFalse(TutorialHarness.named(app, "language.choice.en").isSelected)
		TutorialHarness.attach(self, name: "u9-2-\(entry.rawValue)-automatic-restored", app: app)
		entry.close(app)
		let messages = [
			("english", TutorialHarness.weekQuestion),
			("japanese", "今週の練習はどうでしたか？"),
			("review", "/review"),
		]
		for (name, message) in messages {
			TutorialHarness.exchange(app, message)
			XCTAssertEqual(
				TutorialHarness.named(app, "chat.composer").placeholderValue, "Écris à ton coach")
			TutorialHarness.attach(self, name: "u9-2-\(entry.rawValue)-automatic-\(name)", app: app)
			LanguageProofFlow.assertReplyInstruction(
				app,
				language: .fr,
				test: self, name: "u9-2-\(entry.rawValue)-automatic-\(name)-instruction")
		}
	}
}

@MainActor
final class SavedLanguageFirstFrameProof: XCTestCase {
	private let englishChrome: Set<String> = [
		"Message your coach", "Send message", "Choose your language",
		CatalogPhrasebook(tag: .en).say(Catalog.chatNewConversationLabel),
		"Not medical advice, and not a substitute for a doctor or a certified coach.",
	]

	func testSavedSpanishOpensInSpanishOnAnEnglishPhone() throws {
		let app = XCUIApplication()
		TutorialHarness.launch(app)
		TutorialHarness.completeOnboarding(app)
		TutorialHarness.send(app, "/language")
		let spanish = TutorialHarness.named(app, "language.choice.es")
		TutorialHarness.wait(spanish)
		spanish.tap()
		TutorialHarness.wait(app.navigationBars["Elige tu idioma"])
		TutorialHarness.named(app, "language.close").tap()
		TutorialHarness.relaunchKeepingStore(app)
		let seen = try stringsUntilTheComposer(app)
		TutorialHarness.attach(self, name: "m1-12-saved-spanish-first-frame", app: app)
		let listing = XCTAttachment(string: seen.sorted().joined(separator: "\n"))
		listing.name = "saved-spanish-first-frame-strings"
		listing.lifetime = .keepAlways
		add(listing)
		XCTAssertTrue(seen.contains("Escribe a tu entrenador"), "first frame read \(seen.sorted())")
		let english = seen.filter { englishChrome.contains($0) || $0.hasPrefix("Welcome to") }
		XCTAssertTrue(english.isEmpty, "English on the first frame: \(english.sorted())")
		let welcome = TutorialHarness.named(app, "chat.welcome")
		TutorialHarness.wait(welcome)
		XCTAssertTrue(welcome.label.hasPrefix("¡Te doy la bienvenida a"), welcome.label)
	}

	private func stringsUntilTheComposer(_ app: XCUIApplication) throws -> Set<String> {
		var seen = Set<String>()
		var failure: (any Error)?
		TutorialHarness.wait(
			until: {
				do {
					let snapshot = try app.snapshot()
					seen.formUnion(self.strings(in: snapshot))
					return self.contains(snapshot, identifier: "chat.composer")
				} catch {
					failure = error
					return true
				}
			}, message: "the chat composer never appeared after the relaunch")
		if let failure { throw failure }
		return seen
	}

	private func strings(in element: any XCUIElementSnapshot) -> [String] {
		let own = [
			element.label, element.title, element.value as? String, element.placeholderValue,
		]
		.compactMap { $0 }.filter { !$0.isEmpty }
		return own + element.children.flatMap { strings(in: $0) }
	}

	private func contains(_ element: any XCUIElementSnapshot, identifier: String) -> Bool {
		element.identifier == identifier
			|| element.children.contains { contains($0, identifier: identifier) }
	}
}
