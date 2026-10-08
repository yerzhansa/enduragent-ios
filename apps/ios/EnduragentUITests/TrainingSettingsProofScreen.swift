import XCTest

@MainActor
enum TrainingSettingsProofScreen {
	static let blank = "Enter an intervals.icu API key. Your current connection is unchanged."
	static let notSaved =
		"The replacement wasn't saved. Your previous connection is unchanged. Try again."
	static let missing = "intervals.icu is not connected. Connect to add workouts to your calendar."

	static func connectLater(_ test: XCTestCase, dark: Bool) {
		let app = launch(connected: false)
		TutorialHarness.exchange(app, TutorialHarness.weekQuestion)
		XCTAssertEqual(TutorialHarness.lastClaimAccount(app), "unconnected")
		TutorialHarness.returnToChat(app)
		TutorialHarness.openCredentials(app)
		capture(test, app, name: "connect-later-before", dark: dark)
		replace(app, with: "fixture")
		assertAda(app)
		capture(test, app, name: "connect-later-saved", dark: dark)
		let account = TutorialHarness.connectedAccount(app)
		TutorialHarness.relaunchKeepingStore(app)
		TutorialHarness.waitForLabel(app, TutorialHarness.weekQuestion)
		TutorialHarness.openCredentials(app)
		XCTAssertEqual(TutorialHarness.connectedAccount(app), account)
		TutorialHarness.named(app, "training.edit").tap()
		assertEmptyKey(app)
		TutorialHarness.type(app, "abandoned-key", into: "training.apiKey")
		TutorialHarness.named(app, "training.cancel").tap()
		TutorialHarness.wait(TutorialHarness.named(app, "training.edit"))
		TutorialHarness.returnToChat(app)
		TutorialHarness.exchange(app, TutorialHarness.remember)
		TutorialHarness.waitForLabel(app, TutorialHarness.rememberReply)
		XCTAssertEqual(TutorialHarness.lastClaimAccount(app), account)
		TutorialHarness.returnToChat(app)
		TutorialHarness.openHistory(app)
		TutorialHarness.waitForLabel(app, "No past conversations yet.")
		capture(test, app, name: "connect-later-history", dark: dark)
		TutorialHarness.returnToChat(app)
	}

	static func transaction(_ test: XCTestCase, dark: Bool) {
		let app = launch()
		TutorialHarness.openCredentials(app)
		assertAda(app)
		let account = TutorialHarness.connectedAccount(app)
		TutorialHarness.named(app, "training.keep").tap()
		TutorialHarness.named(app, "training.edit").tap()
		assertEmptyKey(app)
		TutorialHarness.named(app, "training.save").tap()
		TutorialHarness.waitForIdentifier(app, "training.saved", reading: blank)
		capture(test, app, name: "replacement-blank", dark: dark)
		TutorialHarness.type(app, "abandoned-key", into: "training.apiKey")
		TutorialHarness.named(app, "training.cancel").tap()
		TutorialHarness.wait(TutorialHarness.named(app, "training.edit"))
		XCTAssertEqual(TutorialHarness.connectedAccount(app), account)
		TutorialHarness.named(app, "training.edit").tap()
		assertEmptyKey(app)
		TutorialHarness.named(app, "training.cancel").tap()
		TutorialHarness.returnToChat(app)
		TutorialHarness.exchange(app, TutorialHarness.weekQuestion)
		XCTAssertEqual(TutorialHarness.lastClaimAccount(app), account)
		capture(test, app, name: "replacement-cancel-records", dark: dark)
		TutorialHarness.returnToChat(app)
	}

	static func failedWrite(_ test: XCTestCase, dark: Bool) {
		let app = launch()
		TutorialHarness.openCredentials(app)
		let account = TutorialHarness.connectedAccount(app)
		TutorialHarness.returnToChat(app)
		TutorialHarness.fixtureControl(app, "fixture.failCredentialWrite")
		TutorialHarness.openCredentials(app)
		replace(app, with: "fixture-rotated", saved: false)
		TutorialHarness.waitForIdentifier(app, "training.saved", reading: notSaved)
		assertAda(app)
		capture(test, app, name: "replacement-not-saved", dark: dark)
		TutorialHarness.returnToChat(app)
		TutorialHarness.exchange(app, TutorialHarness.weekQuestion)
		XCTAssertEqual(TutorialHarness.lastClaimAccount(app), account)
		capture(test, app, name: "replacement-not-saved-records", dark: dark)
		TutorialHarness.returnToChat(app)
	}

	static func rotation(_ test: XCTestCase, dark: Bool) {
		let app = launch()
		TutorialHarness.exchange(app, TutorialHarness.workout)
		TutorialHarness.wait(TutorialHarness.named(app, "chat.preview.add"))
		TutorialHarness.openCredentials(app)
		let before = TutorialHarness.connectedAccount(app)
		replace(app, with: "fixture-rotated")
		assertAda(app)
		capture(test, app, name: "same-athlete-saved", dark: dark)
		let after = TutorialHarness.connectedAccount(app)
		XCTAssertNotEqual(after, before)
		XCTAssertTrue(after.hasSuffix(":i1001"))
		TutorialHarness.named(app, "training.edit").tap()
		assertEmptyKey(app)
		TutorialHarness.named(app, "training.cancel").tap()
		TutorialHarness.returnToChat(app)
		let add = TutorialHarness.named(app, "chat.preview.add")
		TutorialHarness.wait(add, until: .enabled)
		add.tap()
		TutorialHarness.waitForLabel(app, TutorialHarness.done)
		capture(test, app, name: "same-athlete-added", dark: dark)
	}

	static func differentAthlete(_ test: XCTestCase, dark: Bool) {
		let app = launch()
		TutorialHarness.exchange(app, TutorialHarness.workout)
		TutorialHarness.wait(TutorialHarness.named(app, "chat.preview.add"), until: .enabled)
		TutorialHarness.openCredentials(app)
		let before = TutorialHarness.connectedAccount(app)
		replace(app, with: "other-athlete", saved: false)
		let alert = app.alerts.firstMatch
		TutorialHarness.wait(alert)
		XCTAssertTrue(alert.staticTexts["Use another athlete?"].exists)
		capture(test, app, name: "different-athlete-confirmation", dark: dark)
		alert.buttons["Cancel"].tap()
		TutorialHarness.wait(alert, until: .absent)
		XCTAssertEqual(TutorialHarness.connectedAccount(app), before)
		assertAda(app)
		replace(app, with: "other-athlete", saved: false)
		TutorialHarness.wait(alert)
		alert.buttons["Switch athlete"].tap()
		TutorialHarness.waitForIdentifier(app, "training.athlete", reading: "Bo Lind")
		TutorialHarness.waitForIdentifier(app, "training.saved", reading: "Saved")
		capture(test, app, name: "different-athlete-saved", dark: dark)
		TutorialHarness.returnToChat(app)
		TutorialHarness.waitForIdentifier(
			app, "chat.preview.notice",
			reading:
				"This workout was prepared for a different intervals.icu athlete. Ask me again to prepare it for the connected athlete."
		)
		XCTAssertFalse(TutorialHarness.named(app, "chat.preview.add").exists)
		XCTAssertFalse(TutorialHarness.named(app, "chat.preview.cancel").exists)
		capture(test, app, name: "different-athlete-old-review", dark: dark)
	}

	static func disconnect(_ test: XCTestCase, dark: Bool) {
		let app = launch()
		TutorialHarness.exchange(app, TutorialHarness.weekQuestion)
		TutorialHarness.startNewConversation(app)
		TutorialHarness.exchange(app, TutorialHarness.remember)
		TutorialHarness.openCredentials(app)
		TutorialHarness.named(app, "training.disconnect").tap()
		let alert = app.alerts.firstMatch
		TutorialHarness.wait(alert)
		capture(test, app, name: "disconnect-confirmation", dark: dark)
		alert.buttons["Cancel"].tap()
		TutorialHarness.wait(alert, until: .absent)
		assertAda(app)
		TutorialHarness.named(app, "training.disconnect").tap()
		TutorialHarness.wait(alert)
		alert.buttons["Disconnect"].tap()
		TutorialHarness.waitForIdentifier(app, "training.notice", reading: missing)
		TutorialHarness.wait(TutorialHarness.named(app, "training.edit"))
		XCTAssertFalse(TutorialHarness.named(app, "training.athlete").exists)
		capture(test, app, name: "disconnected-connect-offered", dark: dark)
		TutorialHarness.returnToChat(app)
		TutorialHarness.waitForLabel(app, TutorialHarness.rememberReply)
		TutorialHarness.openHistory(app)
		let row = TutorialHarness.historyRows(app).firstMatch
		TutorialHarness.wait(row, until: .hittable)
		row.tap()
		TutorialHarness.waitForLabel(app, TutorialHarness.weekQuestion)
		capture(test, app, name: "disconnected-history", dark: dark)
		TutorialHarness.returnToChat(app)
		TutorialHarness.exchange(app, TutorialHarness.weekQuestion)
		XCTAssertEqual(TutorialHarness.lastClaimAccount(app), "unconnected")
		capture(test, app, name: "disconnected-next-turn", dark: dark)
		TutorialHarness.returnToChat(app)
	}

	static func unconnectedCalendar(_ test: XCTestCase, dark: Bool) {
		let app = launch(connected: false)
		TutorialHarness.exchange(app, TutorialHarness.workout)
		let add = TutorialHarness.named(app, "chat.preview.add")
		TutorialHarness.wait(add, until: .enabled)
		add.tap()
		TutorialHarness.waitForIdentifier(app, "chat.review.notice", reading: missing)
		let connect = TutorialHarness.named(app, "chat.review.connect")
		TutorialHarness.wait(connect, until: .hittable)
		XCTAssertEqual(connect.label, "Connect")
		capture(test, app, name: "unconnected-calendar-notice", dark: dark)
		connect.tap()
		assertEmptyKey(app)
		capture(test, app, name: "unconnected-calendar-connect", dark: dark)
		TutorialHarness.named(app, "training.cancel").tap()
		TutorialHarness.returnToChat(app, maximumBackSteps: 1)
		XCTAssertEqual(TutorialHarness.named(app, "chat.review.notice").label, missing)
		XCTAssertTrue(TutorialHarness.named(app, "chat.preview.add").exists)
	}

	private static func launch(connected: Bool = true) -> XCUIApplication {
		let app = XCUIApplication()
		TutorialHarness.launch(app)
		if connected {
			TutorialHarness.completeOnboarding(app)
		} else {
			TutorialHarness.startUnconnected(app)
		}
		return app
	}

	private static func replace(_ app: XCUIApplication, with key: String, saved: Bool = true) {
		TutorialHarness.named(app, "training.edit").tap()
		assertEmptyKey(app)
		TutorialHarness.type(app, key, into: "training.apiKey")
		TutorialHarness.named(app, "training.save").tap()
		if saved { TutorialHarness.waitForIdentifier(app, "training.saved", reading: "Saved") }
	}

	private static func assertEmptyKey(_ app: XCUIApplication) {
		let key = app.secureTextFields["training.apiKey"]
		TutorialHarness.wait(key, until: .hittable)
		XCTAssertEqual(key.value as? String, key.placeholderValue)
		XCTAssertEqual(key.placeholderValue, "intervals.icu API key")
	}

	private static func assertAda(_ app: XCUIApplication) {
		TutorialHarness.waitForIdentifier(app, "training.athlete", reading: "Ada Kovač")
		TutorialHarness.waitForIdentifier(app, "training.fitness", reading: "Fitness 42")
		TutorialHarness.waitForIdentifier(app, "training.fatigue", reading: "Fatigue 49")
		TutorialHarness.waitForIdentifier(app, "training.form", reading: "Form -7")
	}

	private static func capture(
		_ test: XCTestCase, _ app: XCUIApplication, name: String, dark: Bool
	) {
		let luminance = TutorialHarness.meanLuminance(app.screenshot())
		if dark { XCTAssertLessThan(luminance, 0.4) } else { XCTAssertGreaterThan(luminance, 0.4) }
		TutorialHarness.attach(test, name: "\(name)-\(dark ? "dark" : "light")", app: app)
	}
}
