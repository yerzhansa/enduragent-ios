import EnduragentCoach
import EnduragentCoachFixtures
import XCTest

@MainActor
final class SupportLargestTextProof: XCTestCase {
	func testSupportRowsWrap() { SupportLargestText.rowsWrap(self, .en) }
	func testFeedbackStacks() { SupportLargestText.feedbackStacks(self, .en) }
	func testDiagnosticsOrder() { SupportLargestText.diagnosticsOrder(self, .en) }
	func testAboutValueUnderLabel() { SupportLargestText.aboutValueUnderLabel(self, .en) }
	func testReadingOrder() { SupportLargestText.readingOrder(self, .en) }

	func testDefaultSizeKeepsInlineRows() {
		let app = SupportScreen.start()
		SupportScreen.open(app, "settings.about", showing: "about.value.version")
		let version = TutorialHarness.named(app, "about.version")
		let value = TutorialHarness.named(app, "about.value.version")
		XCTAssertEqual(value.frame.minY, version.frame.minY, accuracy: 2)
		XCTAssertGreaterThan(value.frame.minX, version.frame.maxX)
		TutorialHarness.attach(self, name: "about-default-size-light", app: app)
		TutorialHarness.returnToChat(app)
		TutorialHarness.openSettings(app)
		SupportScreen.open(app, "settings.session", showing: "session.historyBudgetRatio.input")
		for field in SupportLargestText.sessionFields {
			let label = TutorialHarness.named(app, "session.\(field).label")
			let input = TutorialHarness.named(app, "session.\(field).input")
			TutorialHarness.wait(input)
			XCTAssertEqual(input.frame.minY, label.frame.minY, accuracy: 2, field)
			XCTAssertGreaterThan(input.frame.minX, label.frame.maxX, field)
		}
		TutorialHarness.attach(self, name: "session-default-size-light", app: app)
		TutorialHarness.returnToChat(app)
		TutorialHarness.openSettings(app)
		SupportScreen.open(app, "settings.feedback", showing: "feedback.field")
		let field = TutorialHarness.named(app, "feedback.field")
		let send = TutorialHarness.named(app, "feedback.send")
		TutorialHarness.wait(send)
		XCTAssertGreaterThanOrEqual(send.frame.minY, field.frame.maxY)
		TutorialHarness.attach(self, name: "feedback-default-size-light", app: app)
	}
}

@MainActor
final class SupportLargestTextDeProof: XCTestCase {
	func testSupportRowsWrap() { SupportLargestText.rowsWrap(self, .de) }
	func testFeedbackStacks() { SupportLargestText.feedbackStacks(self, .de) }
	func testDiagnosticsOrder() { SupportLargestText.diagnosticsOrder(self, .de) }
	func testAboutValueUnderLabel() { SupportLargestText.aboutValueUnderLabel(self, .de) }
	func testReadingOrder() { SupportLargestText.readingOrder(self, .de) }
}

@MainActor
enum SupportLargestText {
	static let sessionFields = ["historyBudgetRatio", "contextWindowOverride"]
	static let note = "The plan card skipped Tuesday and the lap table is cut off."
	static let feedbackOrder = [
		"feedback.prompt", "feedback.field", "feedback.outcome", "feedback.send",
	]
	static let diagnosticsOrder = [
		"diagnostics.notSaving", "diagnostics.explanation", "diagnostics.make",
		"diagnostics.outcome",
	]
	static let aboutOrder = [
		"about.value.name", "about.version", "about.value.version", "about.privacyPolicy",
	]

	static func rowsWrap(_ test: XCTestCase, _ language: LanguageTag) {
		let run = LargestTextScreen.begin(test, language)
		let app = run.app
		let rows: [(row: String, title: CatalogKey, content: String)] = [
			("settings.feedback", Catalog.feedbackTitle, "feedback.field"),
			("settings.diagnostics", Catalog.diagnosticsTitle, "diagnostics.explanation"),
			("settings.about", Catalog.aboutTitle, "about.value.version"),
		]
		for entry in rows {
			LargestTextScreen.openSettings(app)
			let link = run.named(entry.row)
			LargestTextScreen.reveal(app, link, tappable: true)
			XCTAssertEqual(link.label, run.say(entry.title), entry.row)
			LargestTextScreen.assertWhole(app, link)
			attach(test, language, "row-\(entry.row)", app)
			link.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
			TutorialHarness.wait(run.named(entry.content))
			TutorialHarness.returnToChat(app)
		}
	}

	static func feedbackStacks(_ test: XCTestCase, _ language: LanguageTag) {
		let run = LargestTextScreen.begin(test, language)
		let app = run.app
		LargestTextScreen.open(app, row: "settings.feedback", showing: "feedback.field")
		let prompt = run.named("feedback.prompt")
		let field = run.named("feedback.field")
		let send = run.named("feedback.send")
		let empty = fieldSlot(prompt, send)
		LargestTextScreen.reveal(app, send, tappable: true)
		send.tap()
		let refused = SupportScreen.outcome(
			app, "feedback.outcome", run.say(Catalog.feedbackRefusedEmpty))
		XCTAssertGreaterThanOrEqual(refused.frame.minY, field.frame.maxY - 2)
		XCTAssertGreaterThanOrEqual(send.frame.minY, refused.frame.maxY - 2)
		XCTAssertEqual(send.frame.width, field.frame.width, accuracy: 2)
		LargestTextScreen.reveal(app, send, tappable: true)
		LargestTextScreen.assertWhole(app, send)
		attach(test, language, "feedback-stacked", app)
		LargestTextScreen.reveal(app, field, tappable: true)
		field.tap()
		field.typeText(note)
		TutorialHarness.wait(field, until: .value(note))
		let grown = fieldSlot(prompt, send)
		XCTAssertGreaterThan(grown, empty + 1, "the field does not grow with the text")
		let more = " " + note
		field.typeText(more + more)
		TutorialHarness.wait(field, until: .value(note + more + more))
		let capped = fieldSlot(prompt, send)
		XCTAssertGreaterThan(capped, grown + 1, "the field stops growing before its cap")
		field.typeText(more)
		TutorialHarness.wait(field, until: .value(note + more + more + more))
		XCTAssertEqual(
			fieldSlot(prompt, send), capped, accuracy: 1, "the field grows past its cap")
		XCTAssertTrue(app.keyboards.firstMatch.exists, "the keyboard is not up")
		LargestTextScreen.reveal(app, send, tappable: true)
		XCTAssertLessThanOrEqual(send.frame.maxY, SupportScreen.visibleBottom(app) + 1)
		attach(test, language, "feedback-send-above-keyboard", app)
		send.tap()
		SupportScreen.outcome(app, "feedback.outcome", run.say(Catalog.feedbackReceived))
	}

	static func diagnosticsOrder(_ test: XCTestCase, _ language: LanguageTag) {
		let run = LargestTextScreen.begin(test, language, arguments: notSaving)
		let app = run.app
		makeAndCancel(run)
		LargestTextScreen.expectOrder(
			app, diagnosticsOrder, screen: "[\(language.rawValue)] Diagnostics")
		let make = run.named("diagnostics.make")
		LargestTextScreen.reveal(app, make, tappable: true)
		XCTAssertEqual(make.label, run.say(Catalog.diagnosticsMake))
		LargestTextScreen.assertWhole(app, make)
		attach(test, language, "diagnostics-order", app)
	}

	static func aboutValueUnderLabel(_ test: XCTestCase, _ language: LanguageTag) {
		let run = LargestTextScreen.begin(test, language)
		let app = run.app
		LargestTextScreen.open(app, row: "settings.about", showing: "about.value.version")
		let version = run.named("about.version")
		let value = run.named("about.value.version")
		XCTAssertEqual(version.label, run.say(Catalog.aboutVersion))
		XCTAssertEqual(value.label, "0.1.0 (3)")
		XCTAssertGreaterThanOrEqual(value.frame.minY, version.frame.maxY - 2)
		XCTAssertEqual(value.frame.minX, version.frame.minX, accuracy: 2)
		let link = run.named("about.privacyPolicy")
		LargestTextScreen.reveal(app, link, tappable: true)
		XCTAssertEqual(link.label, run.say(Catalog.aboutPrivacyPolicy))
		attach(test, language, "about-value-under-label", app)
		link.tap()
		TutorialHarness.wait(
			XCUIApplication(bundleIdentifier: "com.apple.mobilesafari"), until: .foreground)
		app.activate()
		TutorialHarness.wait(app, until: .foreground)
	}

	static func readingOrder(_ test: XCTestCase, _ language: LanguageTag) {
		let run = LargestTextScreen.begin(test, language, arguments: notSaving)
		let app = run.app
		let screen = { (name: String) in "[\(language.rawValue)] \(name)" }
		LargestTextScreen.open(app, row: "settings.feedback", showing: "feedback.field")
		let send = run.named("feedback.send")
		LargestTextScreen.reveal(app, send, tappable: true)
		send.tap()
		SupportScreen.outcome(app, "feedback.outcome", run.say(Catalog.feedbackRefusedEmpty))
		LargestTextScreen.toTop(app)
		LargestTextScreen.expectOrder(app, feedbackOrder, screen: screen("Feedback"))
		TutorialHarness.returnToChat(app)
		makeAndCancel(run)
		LargestTextScreen.expectOrder(app, diagnosticsOrder, screen: screen("Diagnostics"))
		TutorialHarness.returnToChat(app)
		LargestTextScreen.open(app, row: "settings.about", showing: "about.value.version")
		LargestTextScreen.expectOrder(app, aboutOrder, screen: screen("About"))
		attach(test, language, "about-reading-order", app)
	}

	private static var notSaving: FixtureArguments {
		var arguments = FixtureArguments(onboarded: true)
		arguments.journal = .notSaving
		return arguments
	}

	private static func makeAndCancel(_ run: MatrixRun) {
		let app = run.app
		LargestTextScreen.open(app, row: "settings.diagnostics", showing: "diagnostics.notSaving")
		let make = run.named("diagnostics.make")
		LargestTextScreen.reveal(app, make, tappable: true)
		make.tap()
		let close = app.buttons[SupportScreen.closeShareSheet]
		TutorialHarness.wait(
			until: { close.exists && LargestTextScreen.window(app).contains(close.frame) },
			message: "\(close) did not settle inside the window")
		TutorialHarness.wait(close, until: .hittable)
		close.tap()
		SupportScreen.outcome(app, "diagnostics.outcome", run.say(Catalog.diagnosticsCanceled))
		TutorialHarness.wait(make, until: .enabled)
		LargestTextScreen.toTop(app)
	}

	private static func fieldSlot(_ prompt: XCUIElement, _ send: XCUIElement) -> CGFloat {
		var previous = -CGFloat.infinity
		var current = CGFloat.infinity
		TutorialHarness.wait(
			until: {
				previous = current
				current = send.frame.minY - prompt.frame.maxY
				return current == previous
			}, message: "the Feedback field did not settle")
		return current
	}

	private static func attach(
		_ test: XCTestCase, _ language: LanguageTag, _ screen: String, _ app: XCUIApplication
	) {
		TutorialHarness.attach(test, name: "largest-\(language.rawValue)-\(screen)-light", app: app)
	}
}
