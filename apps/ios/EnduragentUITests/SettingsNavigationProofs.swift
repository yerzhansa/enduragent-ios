import EnduragentCoach
import XCTest

@MainActor
final class SettingsNavigationProof: XCTestCase {
	func testConnectedSetupKeepsConversationAndDraft() {
		SettingsNavigationScreen.prove(self, connected: true, dark: false)
	}

	func testSkippedSetupKeepsConversationAndDraft() {
		SettingsNavigationScreen.prove(self, connected: false, dark: false)
	}

	func testFrenchToolbarActionsFit() {
		SettingsNavigationScreen.prove(self, connected: true, language: .fr, dark: false)
	}
}

@MainActor
final class SettingsNavigationDarkProof: XCTestCase {
	func testConnectedSetupKeepsConversationAndDraft() {
		SettingsNavigationScreen.prove(self, connected: true, dark: true)
	}

	func testSkippedSetupKeepsConversationAndDraft() {
		SettingsNavigationScreen.prove(self, connected: false, dark: true)
	}

	func testFrenchToolbarActionsFit() {
		SettingsNavigationScreen.prove(self, connected: true, language: .fr, dark: true)
	}
}

@MainActor
private enum SettingsNavigationScreen {
	static func prove(
		_ test: XCTestCase, connected: Bool, language: LanguageTag = .en, dark: Bool
	) {
		let app = XCUIApplication()
		let phrasebook = CatalogPhrasebook(tag: language)
		let name =
			"settings-\(connected ? "connected" : "skipped")-\(language.rawValue)-\(dark ? "dark" : "light")"
		TutorialHarness.launch(
			app, language: language.rawValue, locale: language == .fr ? "fr_FR" : "en_US")
		if connected {
			TutorialHarness.completeOnboarding(app, language: language)
		} else {
			TutorialHarness.startUnconnected(app)
		}
		TutorialHarness.exchange(app, TutorialHarness.weekQuestion)
		let composer = TutorialHarness.named(app, "chat.composer")
		composer.tap()
		composer.typeText("/")
		TutorialHarness.wait(TutorialHarness.named(app, "chat.slash.review"))
		assertToolbar(app, phrasebook: phrasebook)
		TutorialHarness.attach(test, name: "\(name)-toolbar", app: app)
		assertAppearance(app, dark: dark)
		let connection = trainingConnection(app, connected: connected)
		assertConversation(app)
		openSettings(app, phrasebook: phrasebook)
		TutorialHarness.attach(test, name: "\(name)-page", app: app)
		TutorialHarness.named(app, "settings.credits").tap()
		TutorialHarness.wait(TutorialHarness.named(app, "credits.balance"))
		XCTAssertEqual(
			TutorialHarness.named(app, "credits.balance").label,
			phrasebook.say(Catalog.creditsBalance, count: 200, ["formattedCount": "200"]))
		let buy = app.buttons.matching(
			NSPredicate(format: "label == %@", phrasebook.say(Catalog.creditsBuy)))
		XCTAssertEqual(buy.count, 2)
		for button in buy.allElementsBoundByIndex { XCTAssertFalse(button.isEnabled) }
		TutorialHarness.attach(test, name: "\(name)-credits", app: app)
		TutorialHarness.returnToChat(app)
		assertConversation(app)
		openHistory(app, phrasebook: phrasebook)
		TutorialHarness.waitForLabel(app, phrasebook.say(Catalog.archiveEmpty))
		XCTAssertFalse(TutorialHarness.historyRows(app).firstMatch.exists)
		TutorialHarness.returnToChat(app)
		openSettings(app, phrasebook: phrasebook)
		TutorialHarness.relaunchKeepingStore(app)
		TutorialHarness.wait(composer, until: .hittable)
		assertConversation(app)
		assertToolbar(app, phrasebook: phrasebook)
		XCTAssertEqual(trainingConnection(app, connected: connected), connection)
		openSettings(app, phrasebook: phrasebook)
		TutorialHarness.returnToChat(app)
		openHistory(app, phrasebook: phrasebook)
		TutorialHarness.waitForLabel(app, phrasebook.say(Catalog.archiveEmpty))
		TutorialHarness.returnToChat(app)
		let command = TutorialHarness.named(app, "chat.slash.review")
		TutorialHarness.wait(command, until: .hittable)
		command.tap()
		XCTAssertEqual(composer.value as? String, "/review ")
		TutorialHarness.attach(test, name: "\(name)-command", app: app)
		TutorialHarness.startNewConversation(app, language: language)
		openHistory(app, phrasebook: phrasebook)
		let row = TutorialHarness.historyRows(app).firstMatch
		TutorialHarness.wait(row, until: .hittable)
		XCTAssertEqual(TutorialHarness.historyRows(app).count, 1)
		row.tap()
		TutorialHarness.waitForLabel(app, TutorialHarness.weekQuestion)
		TutorialHarness.waitForLabel(app, TutorialHarness.weekReply)
		TutorialHarness.waitForIdentifier(
			app, "archive.readOnly", reading: phrasebook.say(Catalog.archiveReadOnly))
		XCTAssertFalse(composer.isHittable)
		XCTAssertFalse(TutorialHarness.named(app, "chat.send").isHittable)
		TutorialHarness.attach(test, name: "\(name)-archive", app: app)
		TutorialHarness.returnToChat(app)
		TutorialHarness.assertZeroFixtureRequests(app)
	}

	private static func assertToolbar(_ app: XCUIApplication, phrasebook: CatalogPhrasebook) {
		XCTAssertEqual(app.frame.width, 390, accuracy: 1, "run on a 390 pt wide iPhone")
		let controls = [
			("chat.history", Catalog.archiveHistory),
			("chat.settings", Catalog.settingsTitle),
			("chat.newConversation", Catalog.chatNewConversationLabel),
		]
		let frames = controls.map { identifier, key in
			let button = TutorialHarness.named(app, identifier)
			TutorialHarness.wait(button, until: .hittable)
			XCTAssertEqual(button.label, phrasebook.say(key))
			XCTAssertEqual(button.staticTexts.count, 0)
			TutorialHarness.assertIconButtonWidth(button)
			XCTAssertTrue(app.frame.contains(button.frame))
			return button.frame
		}
		for index in frames.indices {
			for other in frames.indices where index < other {
				XCTAssertFalse(frames[index].intersects(frames[other]))
			}
		}
		XCTAssertFalse(TutorialHarness.named(app, "chat.sidebar").exists)
	}

	private static func openSettings(_ app: XCUIApplication, phrasebook: CatalogPhrasebook) {
		TutorialHarness.openSettings(app)
		TutorialHarness.wait(app.navigationBars[phrasebook.say(Catalog.settingsTitle)])
		TutorialHarness.waitForLabel(app, phrasebook.say(Catalog.settingsModelAccessTitle))
		XCTAssertTrue(TutorialHarness.named(app, "settings.debug").exists)
		XCTAssertEqual(app.cells.count, 2, "only Credits and Debug have Settings rows")
	}

	private static func openHistory(_ app: XCUIApplication, phrasebook: CatalogPhrasebook) {
		TutorialHarness.openHistory(app)
		TutorialHarness.wait(app.navigationBars[phrasebook.say(Catalog.archiveHistory)])
	}

	private static func assertConversation(_ app: XCUIApplication) {
		TutorialHarness.wait(
			TutorialHarness.named(app, "chat.turnProgress"), until: .value("turns 1 settled 1"))
		XCTAssertEqual(TutorialHarness.named(app, "chat.composer").value as? String, "/")
		TutorialHarness.wait(TutorialHarness.named(app, "chat.slash.review"))
	}

	private static func trainingConnection(_ app: XCUIApplication, connected: Bool) -> String {
		TutorialHarness.openCredentials(app)
		let value = TutorialHarness.named(app, "credentials.connection").label
		XCTAssertEqual(
			TutorialHarness.named(app, "credentials.athlete").label, connected ? "Ada Kovač" : "—")
		if connected {
			XCTAssertTrue(value.hasSuffix(" i1001"))
		} else {
			XCTAssertEqual(value, "unconnected")
		}
		TutorialHarness.returnToChat(app)
		return value
	}

	private static func assertAppearance(_ app: XCUIApplication, dark: Bool) {
		let luminance = TutorialHarness.meanLuminance(app.screenshot())
		if dark {
			XCTAssertLessThan(luminance, 0.4, "the capture is not in dark appearance")
		} else {
			XCTAssertGreaterThan(luminance, 0.4, "the capture is not in light appearance")
		}
	}
}
