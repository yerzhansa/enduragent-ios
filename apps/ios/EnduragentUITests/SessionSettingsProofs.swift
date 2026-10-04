import EnduragentCoach
import XCTest

@MainActor
final class SessionSettingsProof: XCTestCase {
	func testEditsSurviveRelaunchWithCredits() {
		SessionSettingsScreen.proveEdits(self, access: .credits, dark: false)
	}

	func testEditsSurviveRelaunchWithAnOpenRouterAccount() {
		SessionSettingsScreen.proveEdits(self, access: .catalogOpenRouter, dark: false)
	}

	func testCancelLeavesTheEditUnapplied() {
		SessionSettingsScreen.proveCancel(self, dark: false)
	}

	func testFailedSaveKeepsTheSavedValueAndConversation() {
		SessionSettingsScreen.proveFailedSave(self, dark: false)
	}
}

@MainActor
final class SessionSettingsDarkProof: XCTestCase {
	func testEditsSurviveRelaunchWithCredits() {
		SessionSettingsScreen.proveEdits(self, access: .credits, dark: true)
	}

	func testEditsSurviveRelaunchWithAnOpenRouterAccount() {
		SessionSettingsScreen.proveEdits(self, access: .catalogOpenRouter, dark: true)
	}

	func testCancelLeavesTheEditUnapplied() {
		SessionSettingsScreen.proveCancel(self, dark: true)
	}

	func testFailedSaveKeepsTheSavedValueAndConversation() {
		SessionSettingsScreen.proveFailedSave(self, dark: true)
	}
}

@MainActor
final class SessionRejectionProof: XCTestCase {
	func testSessionRejection() {
		SessionSettingsScreen.proveRejection(self, dark: false)
	}
}

@MainActor
final class SessionRejectionDarkProof: XCTestCase {
	func testSessionRejection() {
		SessionSettingsScreen.proveRejection(self, dark: true)
	}
}

@MainActor
final class RatioAppliesProof: XCTestCase {
	func testRatioApplies() throws {
		try proveEarlierSummary(.historyBudgetRatio, "5", name: "ratio-applies")
	}

	func testContextWindowApplies() throws {
		try proveEarlierSummary(.contextWindowOverride, "64000", name: "context-window-applies")
	}

	private func proveEarlierSummary(
		_ field: SessionSettingsScreen.Field, _ value: String, name: String
	) throws {
		let app = XCUIApplication()
		let atDefault = firstSummaryTurn(app, edit: nil, name: name)
		let edited = firstSummaryTurn(app, edit: (field, value), name: name)
		let result = XCTAttachment(
			string:
				"compactionSummary first written on turn: default \(atDefault.map(String.init) ?? "none"), \(field.rawValue) \(value) \(edited.map(String.init) ?? "none")"
		)
		result.name = "\(name)-turns"
		result.lifetime = .keepAlways
		add(result)
		XCTAssertLessThan(try XCTUnwrap(edited), try XCTUnwrap(atDefault))
	}

	private func firstSummaryTurn(
		_ app: XCUIApplication, edit: (field: SessionSettingsScreen.Field, value: String)?,
		name: String
	) -> Int? {
		TutorialHarness.launch(app)
		TutorialHarness.completeOnboarding(app)
		if let edit {
			SessionSettingsScreen.open(app)
			SessionSettingsScreen.enter(app, edit.field, edit.value)
			SessionSettingsScreen.save(app)
			TutorialHarness.wait(
				SessionSettingsScreen.input(app, edit.field), until: .value(edit.value))
			TutorialHarness.returnToChat(app)
			TutorialHarness.relaunchKeepingStore(app)
			TutorialHarness.wait(TutorialHarness.named(app, "chat.composer"))
		}
		for turn in 1...9 {
			TutorialHarness.exchange(app, "fixture:long", within: .longTurn)
			TutorialHarness.openRecords(app)
			let written = TutorialHarness.recordCount(app, "compactionSummary") != nil
			if written, edit != nil {
				TutorialHarness.attach(self, name: name, app: app)
			}
			TutorialHarness.returnToChat(app)
			if written {
				return turn
			}
		}
		return nil
	}
}

@MainActor
enum SessionSettingsScreen {
	enum Field: String, CaseIterable {
		case historyBudgetRatio
		case contextWindowOverride
	}

	static let notSaved =
		"Couldn't save your choice on this iPhone, so nothing was changed. Try again."
	private static var phrasebook: CatalogPhrasebook { CatalogPhrasebook(tag: .en) }

	static func open(_ app: XCUIApplication) {
		TutorialHarness.openSettings(app)
		let row = TutorialHarness.named(app, "settings.session")
		TutorialHarness.scroll(app, to: row)
		row.tap()
		TutorialHarness.wait(app.navigationBars["Session"])
		TutorialHarness.wait(input(app, .historyBudgetRatio))
	}

	static func input(_ app: XCUIApplication, _ field: Field) -> XCUIElement {
		TutorialHarness.named(app, "session.\(field.rawValue).input")
	}

	static func enter(_ app: XCUIApplication, _ field: Field, _ value: String) {
		let input = input(app, field)
		TutorialHarness.wait(input, until: .hittable)
		let shown = input.value as? String ?? ""
		input.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
		input.typeText(
			String(repeating: XCUIKeyboardKey.delete.rawValue, count: shown.count) + value)
		TutorialHarness.wait(input, until: .value(value))
		input.typeText("\n")
	}

	static func save(_ app: XCUIApplication) {
		let save = TutorialHarness.named(app, "session.save")
		TutorialHarness.wait(save, until: .hittable)
		XCTAssertEqual(save.label, "Save")
		save.tap()
	}

	static func cancel(_ app: XCUIApplication) {
		let cancel = TutorialHarness.named(app, "session.cancel")
		TutorialHarness.wait(cancel, until: .hittable)
		XCTAssertEqual(cancel.label, "Cancel")
		cancel.tap()
		TutorialHarness.wait(cancel, until: .absent)
	}

	static func assertShown(
		_ app: XCUIApplication, ratio: String, window: String,
		file: StaticString = #filePath, line: UInt = #line
	) {
		TutorialHarness.wait(
			input(app, .historyBudgetRatio), until: .value(ratio), file: file, line: line)
		TutorialHarness.wait(
			input(app, .contextWindowOverride), until: .value(window), file: file, line: line)
		XCTAssertFalse(
			TutorialHarness.named(app, "session.save").exists, "an edit is still open",
			file: file, line: line)
	}

	static func proveEdits(_ test: XCTestCase, access: FixtureAccessMethod, dark: Bool) {
		let app = XCUIApplication()
		let name = "session-\(access.rawValue)-\(dark ? "dark" : "light")"
		launch(app, access: access)
		assertAppearance(app, dark: dark)
		open(app)
		assertShown(app, ratio: "30", window: "")
		assertCatalogText(app)
		TutorialHarness.attach(test, name: "\(name)-defaults", app: app)
		enter(app, .historyBudgetRatio, "5")
		save(app)
		assertShown(app, ratio: "5", window: "")
		reopenAfterRelaunch(app)
		assertShown(app, ratio: "5", window: "")
		TutorialHarness.attach(test, name: "\(name)-ratio-reopened", app: app)
		enter(app, .contextWindowOverride, "64000")
		save(app)
		assertShown(app, ratio: "5", window: "64000")
		reopenAfterRelaunch(app)
		assertShown(app, ratio: "5", window: "64000")
		TutorialHarness.attach(test, name: "\(name)-window-reopened", app: app)
		enter(app, .contextWindowOverride, "")
		save(app)
		assertShown(app, ratio: "5", window: "")
		TutorialHarness.returnToChat(app)
		TutorialHarness.openSettings(app)
		XCTAssertEqual(
			TutorialHarness.named(app, "settings.model").exists, access == .catalogOpenRouter)
		TutorialHarness.returnToChat(app)
		TutorialHarness.openRecords(app)
		XCTAssertEqual(TutorialHarness.recordCount(app, "sessionSettings"), "sessionSettings 3")
		TutorialHarness.returnToChat(app)
		TutorialHarness.exchange(app, TutorialHarness.weekQuestion)
		TutorialHarness.waitForLabel(app, TutorialHarness.weekReply)
	}

	static func proveCancel(_ test: XCTestCase, dark: Bool) {
		let app = XCUIApplication()
		let appearance = dark ? "dark" : "light"
		launch(app, access: .credits)
		assertAppearance(app, dark: dark)
		open(app)
		enter(app, .historyBudgetRatio, "5")
		enter(app, .contextWindowOverride, "64000")
		TutorialHarness.attach(test, name: "session-cancel-editing-\(appearance)", app: app)
		cancel(app)
		assertShown(app, ratio: "30", window: "")
		TutorialHarness.attach(test, name: "session-cancel-restored-\(appearance)", app: app)
		enter(app, .historyBudgetRatio, "7")
		TutorialHarness.returnToChat(app)
		open(app)
		assertShown(app, ratio: "30", window: "")
		reopenAfterRelaunch(app)
		assertShown(app, ratio: "30", window: "")
		TutorialHarness.returnToChat(app)
		TutorialHarness.openRecords(app)
		XCTAssertNil(TutorialHarness.recordCount(app, "sessionSettings"))
		TutorialHarness.returnToChat(app)
	}

	static func proveRejection(_ test: XCTestCase, dark: Bool) {
		let app = XCUIApplication()
		let appearance = dark ? "dark" : "light"
		launch(app, access: .credits)
		assertAppearance(app, dark: dark)
		open(app)
		let rows: [(field: Field, sentence: String)] = [
			(.historyBudgetRatio, "Enter a history budget above 0% and no more than 100%."),
			(.contextWindowOverride, "Enter a safe whole number of tokens, 1 or more."),
		]
		for row in rows {
			enter(app, row.field, "0")
			save(app)
			TutorialHarness.waitForIdentifier(
				app, "session.\(row.field.rawValue).rejection", reading: row.sentence)
			XCTAssertFalse(TutorialHarness.named(app, "session.saveFailed").exists)
			TutorialHarness.attach(
				test, name: "session-rejected-\(row.field.rawValue)-\(appearance)", app: app)
			cancel(app)
			XCTAssertFalse(
				TutorialHarness.named(app, "session.\(row.field.rawValue).rejection").exists)
			assertShown(app, ratio: "30", window: "")
		}
		TutorialHarness.returnToChat(app)
		TutorialHarness.openRecords(app)
		XCTAssertNil(TutorialHarness.recordCount(app, "sessionSettings"))
		TutorialHarness.returnToChat(app)
		reopenAfterRelaunch(app)
		assertShown(app, ratio: "30", window: "")
	}

	static func proveFailedSave(_ test: XCTestCase, dark: Bool) {
		let app = XCUIApplication()
		let appearance = dark ? "dark" : "light"
		launch(app, access: .credits)
		assertAppearance(app, dark: dark)
		TutorialHarness.exchange(app, TutorialHarness.weekQuestion)
		open(app)
		enter(app, .contextWindowOverride, "64000")
		save(app)
		assertShown(app, ratio: "30", window: "64000")
		TutorialHarness.returnToChat(app)
		TutorialHarness.fixtureControl(app, "fixture.failNextAppend")
		open(app)
		enter(app, .historyBudgetRatio, "5")
		save(app)
		TutorialHarness.waitForIdentifier(app, "session.saveFailed", reading: notSaved)
		TutorialHarness.wait(input(app, .historyBudgetRatio), until: .value("5"))
		TutorialHarness.attach(test, name: "session-save-failed-\(appearance)", app: app)
		cancel(app)
		XCTAssertFalse(TutorialHarness.named(app, "session.saveFailed").exists)
		assertShown(app, ratio: "30", window: "64000")
		TutorialHarness.returnToChat(app)
		assertConversation(app)
		TutorialHarness.openRecords(app)
		XCTAssertEqual(TutorialHarness.recordCount(app, "sessionSettings"), "sessionSettings 1")
		TutorialHarness.returnToChat(app)
		reopenAfterRelaunch(app)
		assertShown(app, ratio: "30", window: "64000")
		TutorialHarness.attach(test, name: "session-save-failed-reopened-\(appearance)", app: app)
		TutorialHarness.returnToChat(app)
		assertConversation(app)
	}

	private static func launch(_ app: XCUIApplication, access: FixtureAccessMethod) {
		TutorialHarness.launch(
			app, arguments: FixtureArguments(onboarded: true, accessMethod: access))
		TutorialHarness.agreeToProviderConsent(app)
		TutorialHarness.wait(TutorialHarness.named(app, "chat.composer"), until: .hittable)
	}

	private static func reopenAfterRelaunch(_ app: XCUIApplication) {
		TutorialHarness.relaunchKeepingStore(app)
		TutorialHarness.wait(TutorialHarness.named(app, "chat.composer"), until: .hittable)
		open(app)
	}

	private static func assertCatalogText(_ app: XCUIApplication) {
		let window = input(app, .contextWindowOverride)
		XCTAssertEqual(window.placeholderValue, "Default")
		XCTAssertEqual(input(app, .historyBudgetRatio).placeholderValue, "30")
		XCTAssertEqual(TutorialHarness.named(app, "session.historyBudgetRatio.unit").label, "%")
		XCTAssertEqual(
			TutorialHarness.named(app, "session.contextWindowOverride.unit").label, "tokens")
		let shown = [
			Catalog.settingsConversationFieldsHistoryTokenBudgetRatioLabel,
			Catalog.settingsConversationFieldsHistoryTokenBudgetRatioHelp,
			Catalog.settingsSessionContextWindowLabel, Catalog.settingsSessionContextWindowHelp,
		]
		for key in shown {
			XCTAssertTrue(
				app.staticTexts[phrasebook.say(key)].exists, "\(key.rawValue) is not shown")
		}
		let retired = [
			Catalog.settingsConversationFieldsIdleMinutesLabel,
			Catalog.settingsConversationFieldsDailyResetHourLabel,
			Catalog.settingsConversationFieldsTimezoneLabel,
			Catalog.settingsConversationFieldsResetArchiveRetentionDaysLabel,
			Catalog.settingsCoachChooseModel,
		]
		for key in retired {
			XCTAssertFalse(
				TutorialHarness.text(app, containing: phrasebook.say(key)).exists,
				"\(key.rawValue) is shown")
		}
		XCTAssertFalse(TutorialHarness.named(app, "session.save").exists)
		XCTAssertFalse(TutorialHarness.named(app, "session.cancel").exists)
	}

	private static func assertConversation(_ app: XCUIApplication) {
		TutorialHarness.wait(
			TutorialHarness.named(app, "chat.turnProgress"), until: .value("turns 1 settled 1"))
		XCTAssertTrue(app.staticTexts[TutorialHarness.weekQuestion].exists)
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
