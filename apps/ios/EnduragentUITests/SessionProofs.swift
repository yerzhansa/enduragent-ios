import EnduragentCoach
import XCTest

@MainActor
final class LanguagePickerProof: XCTestCase {
	private let english = [
		"Automatic", "English", "Español", "Français", "Italiano", "Deutsch", "Nederlands",
		"Dansk", "Svenska", "Norsk bokmål", "Suomi", "Português (Portugal)",
		"Português (Brasil)", "Polski", "한국어", "日本語", "简体中文", "繁體中文",
	]

	func testLanguagePicker() {
		let app = XCUIApplication()
		TutorialHarness.launch(app)
		TutorialHarness.completeOnboarding(app)
		TutorialHarness.wait(app.navigationBars["Chat"])
		TutorialHarness.send(app, "/language")
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
		TutorialHarness.attach(self, name: "language-picker-auto", app: app)
		let french = TutorialHarness.named(app, "language.choice.fr")
		let switched = timedChoice(french, until: app.navigationBars["Choisis ta langue"])
		XCTAssertTrue(french.isSelected)
		XCTAssertFalse(automatic.isSelected)
		TutorialHarness.attach(self, name: "language-picker-fr", app: app)
		let unchanged = timedChoice(french, until: app.navigationBars["Choisis ta langue"])
		XCTAssertTrue(french.isSelected)
		record(switched: switched, unchanged: unchanged)
		XCTAssertEqual(scrolledChoiceLabels(app), ["Automatique"] + english.dropFirst())
		TutorialHarness.named(app, "language.close").tap()
		TutorialHarness.wait(app.navigationBars["Conversation"])
		XCTAssertEqual(
			TutorialHarness.named(app, "chat.composer").placeholderValue, "Écris à ton coach")
		TutorialHarness.exchange(app, TutorialHarness.weekQuestion)
		TutorialHarness.openSidebar(app)
		TutorialHarness.named(app, "sidebar.debug").tap()
		let replyLanguage = TutorialHarness.named(app, "fixture.replyLanguage")
		TutorialHarness.wait(replyLanguage)
		XCTAssertTrue(
			replyLanguage.label.hasPrefix("The athlete chose French (Français)."),
			"reply language reads \(replyLanguage.label)")
		TutorialHarness.closeMenu(app)
		TutorialHarness.attach(self, name: "m1-12-language-fr", app: app)
		TutorialHarness.relaunchKeepingStore(app)
		TutorialHarness.wait(app.navigationBars["Conversation"])
		TutorialHarness.openRecords(app)
		XCTAssertEqual(
			TutorialHarness.recordCount(app, "languagePreference"), "languagePreference 1")
		TutorialHarness.closeMenu(app)
		TutorialHarness.attach(self, name: "m1-12-language-survives", app: app)
	}

	private func choiceLabels(_ app: XCUIApplication) -> [String] {
		app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "language.choice."))
			.allElementsBoundByIndex.filter { $0.isHittable }.map { $0.label }
	}

	private func scrolledChoiceLabels(_ app: XCUIApplication) -> [String] {
		var labels: [String] = []
		for _ in 0..<4 {
			for label in choiceLabels(app) where !labels.contains(label) {
				labels.append(label)
			}
			app.swipeUp(velocity: .slow)
		}
		return labels
	}

	private func timedChoice(_ choice: XCUIElement, until title: XCUIElement) -> TimeInterval {
		let tapped = Date()
		choice.tap()
		XCTAssertTrue(title.waitForExistence(timeout: 5))
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

final class AutomaticFrenchPhoneProof: XCTestCase {
	func testEnglishMessageOnAFrenchPhoneGetsAnEnglishReply() {
		let app = XCUIApplication()
		TutorialHarness.launch(app, language: "fr", locale: "fr_FR")
		TutorialHarness.completeOnboarding(app, language: .fr)
		TutorialHarness.wait(app.navigationBars["Conversation"])
		let phrasebook = CatalogPhrasebook(tag: .fr)
		let button = TutorialHarness.named(app, "chat.newConversation")
		TutorialHarness.waitUntilHittable(button)
		XCTAssertEqual(button.label, phrasebook.say(Catalog.chatNewConversationLabel))
		XCTAssertEqual(button.elementType, .button)
		TutorialHarness.assertIconButtonWidth(button)
		XCTAssertEqual(
			TutorialHarness.named(app, "chat.composer").placeholderValue, "Écris à ton coach")
		TutorialHarness.exchange(app, TutorialHarness.weekQuestion)
		TutorialHarness.waitForLabel(app, TutorialHarness.weekReply)
		TutorialHarness.attach(self, name: "m1-12-automatic-fr-phone", app: app)
		TutorialHarness.openSidebar(app)
		TutorialHarness.named(app, "sidebar.debug").tap()
		let replyLanguage = TutorialHarness.named(app, "fixture.replyLanguage")
		TutorialHarness.wait(replyLanguage)
		XCTAssertTrue(
			replyLanguage.label.hasPrefix(
				"No language is saved. Reply in the language of the athlete's latest message"),
			"reply language reads \(replyLanguage.label)")
		XCTAssertTrue(
			replyLanguage.label.hasSuffix("reply in English (English)."),
			"reply language reads \(replyLanguage.label)")
		TutorialHarness.closeMenu(app)
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
		let deadline = Date().addingTimeInterval(10)
		while Date() < deadline {
			let snapshot = try app.snapshot()
			seen.formUnion(strings(in: snapshot))
			if contains(snapshot, identifier: "chat.composer") {
				return seen
			}
		}
		XCTFail("the chat composer never appeared after the relaunch")
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

final class OvernightConversationProof: XCTestCase {
	func testThirteenHoursLaterContinuesTheConversation() {
		let app = XCUIApplication()
		TutorialHarness.launch(app, clock: "1998-06-15T18:00:00Z")
		TutorialHarness.completeOnboarding(app)
		TutorialHarness.exchange(app, TutorialHarness.weekQuestion)
		TutorialHarness.relaunchKeepingStore(app, clock: "1998-06-16T07:00:00Z")
		TutorialHarness.wait(TutorialHarness.named(app, "chat.composer"))
		TutorialHarness.exchange(app, TutorialHarness.remember)
		TutorialHarness.waitForLabel(app, TutorialHarness.rememberReply)
		XCTAssertTrue(app.staticTexts[TutorialHarness.weekQuestion].exists)
		TutorialHarness.attach(self, name: "m1-15-overnight-continues", app: app)
		TutorialHarness.openRecords(app)
		XCTAssertEqual(TutorialHarness.recordCount(app, "userMessage"), "userMessage 2")
		XCTAssertNil(TutorialHarness.recordCount(app, "windowStart"))
		TutorialHarness.closeMenu(app)
		TutorialHarness.openHistory(app)
		TutorialHarness.waitForLabel(app, "No past conversations yet.")
		XCTAssertFalse(TutorialHarness.historyRows(app).firstMatch.exists)
		TutorialHarness.attach(self, name: "m1-15-overnight-history", app: app)
	}
}

final class SessionRejectionProof: XCTestCase {
	func testSessionRejection() {
		let app = XCUIApplication()
		TutorialHarness.launch(app)
		TutorialHarness.completeOnboarding(app)
		SessionDebug.open(app)
		let rows: [(field: String, value: String, sentence: String, stored: String)] = [
			(
				"historyBudgetRatio", "0", "Enter a history budget above 0% and no more than 100%.",
				"0.3"
			),
			("contextWindowOverride", "0", "Enter a safe whole number of tokens, 1 or more.", "—"),
			(
				"compactionModel", String(repeating: "m", count: 513),
				"Model names must be 512 characters or fewer.", "—"
			),
			(
				"flushModel", String(repeating: "f", count: 513),
				"Model names must be 512 characters or fewer.", "—"
			),
		]
		for row in rows {
			SessionDebug.enter(app, row.field, row.value)
			let outcome = TutorialHarness.named(app, "session.\(row.field).outcome")
			XCTAssertEqual(outcome.label, row.sentence, row.field)
			XCTAssertEqual(
				TutorialHarness.named(app, "session.\(row.field).stored").label, row.stored,
				row.field)
			if row.field == "historyBudgetRatio" {
				TutorialHarness.attach(self, name: "m1-12-rejected", app: app)
			}
		}
		TutorialHarness.attach(self, name: "m1-12-rejected-last", app: app)
		app.navigationBars.buttons.element(boundBy: 0).tap()
		TutorialHarness.named(app, "debug.records").tap()
		TutorialHarness.wait(TutorialHarness.named(app, "records.device"))
		XCTAssertNil(TutorialHarness.recordCount(app, "sessionSettings"))
		TutorialHarness.closeMenu(app)
	}
}

final class RatioAppliesProof: XCTestCase {
	func testRatioApplies() throws {
		let app = XCUIApplication()
		let atDefault = firstSummaryTurn(app, ratio: nil)
		let atSmallRatio = firstSummaryTurn(app, ratio: "0.05")
		let result = XCTAttachment(
			string:
				"compactionSummary first written on turn: default \(atDefault.map(String.init) ?? "none"), ratio 0.05 \(atSmallRatio.map(String.init) ?? "none")"
		)
		result.name = "ratio-applies-turns"
		result.lifetime = .keepAlways
		add(result)
		XCTAssertLessThan(try XCTUnwrap(atSmallRatio), try XCTUnwrap(atDefault))
	}

	private func firstSummaryTurn(_ app: XCUIApplication, ratio: String?) -> Int? {
		TutorialHarness.launch(app)
		TutorialHarness.completeOnboarding(app)
		if let ratio {
			SessionDebug.open(app)
			SessionDebug.enter(app, "historyBudgetRatio", ratio)
			XCTAssertEqual(
				TutorialHarness.named(app, "session.historyBudgetRatio.outcome").label, "Saved")
			TutorialHarness.closeMenu(app)
		}
		for turn in 1...9 {
			TutorialHarness.exchange(app, "fixture:long", timeout: 60)
			TutorialHarness.openRecords(app)
			let written = TutorialHarness.recordCount(app, "compactionSummary") != nil
			if written, ratio != nil {
				TutorialHarness.attach(self, name: "m1-12-ratio-applies", app: app)
			}
			TutorialHarness.closeMenu(app)
			if written {
				return turn
			}
		}
		return nil
	}
}

enum SessionDebug {
	static func open(_ app: XCUIApplication) {
		TutorialHarness.openSidebar(app)
		TutorialHarness.named(app, "sidebar.debug").tap()
		let session = TutorialHarness.named(app, "debug.session")
		TutorialHarness.wait(session)
		session.tap()
		TutorialHarness.wait(TutorialHarness.named(app, "session.historyBudgetRatio.stored"))
	}

	static func enter(_ app: XCUIApplication, _ field: String, _ value: String) {
		let input = TutorialHarness.named(app, "session.\(field).input")
		reveal(input, in: app)
		input.tap()
		input.typeText(value + "\n")
		let save = TutorialHarness.named(app, "session.\(field).save")
		reveal(save, in: app)
		save.tap()
		TutorialHarness.wait(TutorialHarness.named(app, "session.\(field).outcome"))
	}

	private static func reveal(_ element: XCUIElement, in app: XCUIApplication) {
		let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75))
		let to = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
		for _ in 0..<12 where !element.isHittable {
			from.press(forDuration: 0.05, thenDragTo: to)
		}
		TutorialHarness.waitUntilHittable(element)
	}
}
