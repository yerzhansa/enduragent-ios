import EnduragentCoach
import EnduragentCoachFixtures
import XCTest

@MainActor
enum SupportScreen {
	static let phrasebook = CatalogPhrasebook(tag: .en)
	static let note = "The plan card skipped Tuesday."
	static let lapTable = "the lap table is cut off"
	static let other = "other text"
	static let closeShareSheet = "Close"
	static let replaceSavedFile = "Replace"
	static let keyboardAssistant = "SystemInputAssistantView"

	static var notSavingSentence: String {
		let display = DisplayLocale(
			preference: .automatic, preferredLanguages: ["en"],
			regionalConventions: Locale(identifier: "en_US"))
		let clock = FixedClock(now: "1998-06-15T08:00:00Z", timeZone: "Europe/Ljubljana")
		return phrasebook.say(
			Catalog.diagnosticsNotSaving, ["time": display.moment(clock.now, in: clock.timeZone)])
	}

	static func say(_ key: CatalogKey) -> String { phrasebook.say(key) }

	static func start(feedback: String? = nil) -> XCUIApplication {
		var arguments = FixtureArguments()
		arguments.feedback = feedback.flatMap(FixtureFeedbackScript.init(rawValue:))
		return start(arguments)
	}

	static func start(_ arguments: FixtureArguments) -> XCUIApplication {
		let app = chat(arguments)
		TutorialHarness.openSettings(app)
		return app
	}

	static func chat(_ arguments: FixtureArguments = FixtureArguments()) -> XCUIApplication {
		let app = XCUIApplication()
		TutorialHarness.launch(app, arguments: arguments)
		TutorialHarness.startUnconnected(app)
		return app
	}

	static func backOnceToEmptyChat(_ app: XCUIApplication) {
		app.navigationBars.buttons.element(boundBy: 0).tap()
		TutorialHarness.wait(TutorialHarness.named(app, "chat.settings"), until: .hittable)
		XCTAssertEqual(TutorialHarness.named(app, "chat.composer").value as? String, "")
		XCTAssertEqual(
			TutorialHarness.named(app, "chat.turnProgress").value as? String, "turns 0 settled 0")
	}

	static func modelRequests(_ app: XCUIApplication) -> String {
		TutorialHarness.openDebug(app)
		let label = TutorialHarness.debugRow(app, "fixture.modelRequestCount").label
		TutorialHarness.returnToChat(app)
		return label
	}

	@discardableResult
	static func button(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
		let button = TutorialHarness.named(app, identifier)
		assertVisible(app, button)
		return button
	}

	static func replaceNote(_ app: XCUIApplication, with text: String) {
		let field = TutorialHarness.named(app, "feedback.field")
		TutorialHarness.wait(field, until: .hittable)
		let shown = field.value as? String ?? ""
		field.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.9)).tap()
		field.typeText(
			String(repeating: XCUIKeyboardKey.delete.rawValue, count: shown.count) + text)
		TutorialHarness.wait(field, until: .value(text))
	}

	static func startSharing() -> XCUIApplication {
		let app = start()
		open(app, "settings.diagnostics", showing: "diagnostics.make")
		TutorialHarness.named(app, "diagnostics.make").tap()
		TutorialHarness.wait(app.buttons[closeShareSheet], until: .hittable)
		return app
	}

	static func open(_ app: XCUIApplication, _ row: String, showing content: String) {
		let link = TutorialHarness.named(app, row)
		TutorialHarness.scroll(app, to: link)
		link.tap()
		TutorialHarness.wait(TutorialHarness.named(app, content))
	}

	@discardableResult
	static func outcome(
		_ app: XCUIApplication, _ identifier: String, _ sentence: String
	) -> XCUIElement {
		let element = line(app, identifier, sentence)
		TutorialHarness.wait(element)
		return element
	}

	static func line(_ app: XCUIApplication, _ identifier: String, _ sentence: String)
		-> XCUIElement
	{
		app.descendants(matching: .any).matching(
			NSPredicate(format: "identifier == %@ AND label == %@", identifier, sentence)
		).firstMatch
	}

	static func assertVisible(
		_ app: XCUIApplication, _ element: XCUIElement,
		file: StaticString = #filePath, line: UInt = #line
	) {
		TutorialHarness.wait(
			until: {
				element.exists && element.isHittable
					&& element.frame.maxY <= visibleBottom(app)
			},
			message: "\(element) is not wholly above the keyboard",
			file: file, line: line)
	}

	static func visibleBottom(_ app: XCUIApplication) -> CGFloat {
		let covers = [app.keyboards.firstMatch, app.otherElements[keyboardAssistant]]
			.filter(\.exists)
		return covers.map(\.frame.minY).min() ?? app.windows.firstMatch.frame.maxY
	}

	static func shareAction(_ app: XCUIApplication, _ label: String) -> XCUIElement {
		let action = app.descendants(matching: .any).matching(
			NSPredicate(format: "label == %@", label)
		).firstMatch
		TutorialHarness.wait(action, until: .hittable)
		return action
	}

	static func tryAgain(_ app: XCUIApplication) {
		let button = TutorialHarness.named(app, "feedback.tryAgain")
		assertVisible(app, button)
		XCTAssertEqual(button.label, say(Catalog.chatTranscriptRetry))
		button.tap()
		assertVisible(app, outcome(app, "feedback.outcome", say(Catalog.feedbackReceived)))
	}

	static func assertFeedbackCounts(_ app: XCUIApplication, requests: Int, stored: Int) {
		TutorialHarness.returnToChat(app)
		TutorialHarness.openDebug(app)
		XCTAssertEqual(
			TutorialHarness.debugRow(app, "fixture.feedbackRequests").label,
			"\(requests) feedback requests")
		XCTAssertEqual(
			TutorialHarness.debugRow(app, "fixture.feedbackStored").label,
			"\(stored) feedback notes stored")
		TutorialHarness.returnToChat(app)
	}
}
