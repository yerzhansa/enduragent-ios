import XCTest

@MainActor
final class TrainingStorageProof: XCTestCase {
	func testUnavailableStorageRecovers() {
		TrainingStorageProofScreen.unavailable(self, dark: false)
	}

	func testMalformedStorageCanBeCorrected() {
		TrainingStorageProofScreen.malformed(self, dark: false)
	}
}

@MainActor
final class TrainingStorageDarkProof: XCTestCase {
	func testUnavailableStorageRecovers() {
		TrainingStorageProofScreen.unavailable(self, dark: true)
	}

	func testMalformedStorageCanBeCorrected() {
		TrainingStorageProofScreen.malformed(self, dark: true)
	}
}

@MainActor
enum TrainingStorageProofScreen {
	static let locked = "Unlock your iPhone to read your intervals.icu connection. Then try again."
	static let unavailable =
		"Your intervals.icu connection is temporarily unavailable because secure storage couldn't be read. Try again."
	static let malformed =
		"The saved intervals.icu connection couldn't be read. Replace the key to connect again."
	static let secrets = [
		"fixture-malformed-secret", "fixture-credits-key", "synthetic-correction-key",
	]

	static func unavailable(_ test: XCTestCase, dark: Bool) {
		let app = connectedConversation()
		TutorialHarness.relaunchKeepingStore(app, keychain: .unavailable)
		TutorialHarness.waitForIdentifier(
			app, "chat.composer.notice",
			reading:
				"Secure storage is temporarily unavailable. Your conversation, History and memory are still here. Try again."
		)
		assertConversation(app)
		openTraining(app)
		TutorialHarness.waitForIdentifier(app, "training.notice", reading: unavailable)
		XCTAssertFalse(TutorialHarness.named(app, "training.edit").exists)
		XCTAssertEqual(TutorialHarness.named(app, "training.displayAction").label, "Try again")
		capture(test, app, name: "training-storage-unavailable", dark: dark)
		TutorialHarness.returnToChat(app)
		TutorialHarness.fixtureControl(app, "fixture.restoreSecureStorage")
		openTraining(app)
		TutorialHarness.named(app, "training.displayAction").tap()
		TutorialHarness.waitForIdentifier(app, "training.athlete", reading: "Ada Kovač")
		TutorialHarness.waitForIdentifier(app, "training.fitness", reading: "Fitness 42")
		TutorialHarness.wait(TutorialHarness.named(app, "training.notice"), until: .absent)
		capture(test, app, name: "training-storage-recovered", dark: dark)
		TutorialHarness.returnToChat(app)
		assertConversation(app)
		TutorialHarness.wait(TutorialHarness.named(app, "chat.composer.notice"), until: .absent)
		assertRecordsContainNoSecrets(app)
		TutorialHarness.assertZeroFixtureRequests(app)
	}

	static func malformed(_ test: XCTestCase, dark: Bool) {
		let app = connectedConversation()
		TutorialHarness.relaunchKeepingStore(app, keychain: .malformedIntervals)
		assertConversation(app)
		openTraining(app)
		TutorialHarness.waitForIdentifier(app, "training.notice", reading: malformed)
		XCTAssertEqual(TutorialHarness.named(app, "training.edit").label, "Replace key")
		capture(test, app, name: "training-storage-malformed", dark: dark)
		TutorialHarness.named(app, "training.edit").tap()
		assertEmptyKey(app)
		TutorialHarness.named(app, "training.cancel").tap()
		TutorialHarness.wait(TutorialHarness.named(app, "training.edit"))
		TutorialHarness.waitForIdentifier(app, "training.notice", reading: malformed)
		TutorialHarness.named(app, "training.edit").tap()
		TutorialHarness.named(app, "training.save").tap()
		TutorialHarness.waitForIdentifier(
			app, "training.saved", reading: "Enter an intervals.icu API key.")
		TutorialHarness.waitForIdentifier(app, "training.notice", reading: malformed)
		TutorialHarness.named(app, "training.cancel").tap()
		TutorialHarness.returnToChat(app)
		TutorialHarness.fixtureControl(app, "fixture.failCredentialWrite")
		openTraining(app)
		TutorialHarness.named(app, "training.edit").tap()
		assertEmptyKey(app)
		TutorialHarness.type(app, "synthetic-correction-key", into: "training.apiKey")
		TutorialHarness.named(app, "training.save").tap()
		TutorialHarness.waitForIdentifier(
			app, "training.saved", reading: "The connection wasn't saved. Try again.")
		TutorialHarness.waitForIdentifier(app, "training.notice", reading: malformed)
		capture(test, app, name: "training-correction-not-saved", dark: dark)
		TutorialHarness.named(app, "training.save").tap()
		TutorialHarness.waitForIdentifier(app, "training.saved", reading: "Saved")
		TutorialHarness.waitForIdentifier(app, "training.athlete", reading: "Ada Kovač")
		TutorialHarness.waitForIdentifier(app, "training.form", reading: "Form -7")
		XCTAssertFalse(TutorialHarness.named(app, "training.apiKey").exists)
		capture(test, app, name: "training-correction-saved", dark: dark)
		TutorialHarness.returnToChat(app)
		assertConversation(app)
		TutorialHarness.exchange(app, "fixture:training-data")
		TutorialHarness.waitForLabel(app, "I can read Ada Kovač's training profile and calendar.")
		assertNoSecrets(app)
		assertRecordsContainNoSecrets(app)
		TutorialHarness.assertZeroFixtureRequests(app)
	}

	static func openTraining(_ app: XCUIApplication) {
		TutorialHarness.openSettings(app)
		TutorialHarness.named(app, "settings.training").tap()
		TutorialHarness.wait(TutorialHarness.named(app, "training.notice"))
	}

	static func assertNoSecrets(_ app: XCUIApplication) {
		let labels = app.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: "\n")
		for secret in secrets { XCTAssertFalse(labels.contains(secret)) }
	}

	private static func connectedConversation() -> XCUIApplication {
		let app = XCUIApplication()
		TutorialHarness.launch(app)
		TutorialHarness.completeOnboarding(app)
		TutorialHarness.exchange(app, TutorialHarness.remember)
		TutorialHarness.waitForLabel(app, TutorialHarness.rememberReply)
		return app
	}

	private static func assertConversation(_ app: XCUIApplication) {
		TutorialHarness.waitForLabel(app, TutorialHarness.remember)
		TutorialHarness.waitForLabel(app, TutorialHarness.rememberReply)
		XCTAssertFalse(TutorialHarness.named(app, "notice.continue").exists)
		assertNoSecrets(app)
	}

	private static func assertEmptyKey(_ app: XCUIApplication) {
		let field = app.secureTextFields["training.apiKey"]
		TutorialHarness.wait(field, until: .hittable)
		XCTAssertEqual(field.value as? String, field.placeholderValue)
		XCTAssertEqual(field.placeholderValue, "intervals.icu API key")
	}

	private static func assertRecordsContainNoSecrets(_ app: XCUIApplication) {
		TutorialHarness.openRecords(app)
		let rows = TutorialHarness.recordRowLabels(app)
		XCTAssertFalse(rows.isEmpty)
		for secret in secrets { XCTAssertFalse(rows.contains { $0.contains(secret) }) }
		TutorialHarness.returnToChat(app)
	}

	private static func capture(
		_ test: XCTestCase, _ app: XCUIApplication, name: String, dark: Bool
	) {
		assertNoSecrets(app)
		let luminance = TutorialHarness.meanLuminance(app.screenshot())
		if dark { XCTAssertLessThan(luminance, 0.4) } else { XCTAssertGreaterThan(luminance, 0.4) }
		TutorialHarness.attach(test, name: "\(name)-\(dark ? "dark" : "light")", app: app)
	}
}
