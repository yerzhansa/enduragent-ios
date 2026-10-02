import XCTest

@MainActor
final class CancelUnknownSaveProof: XCTestCase {
	func testCancelOfflinePersistsAndAllowsFreshReviews() {
		ReviewRecoveryScreen.cancel(self, locked: false, dark: false)
	}

	func testCancelWithLockedCredentialPersistsAndAllowsFreshReviews() {
		ReviewRecoveryScreen.cancel(self, locked: true, dark: false)
	}
}

@MainActor
final class CancelUnknownSaveDarkProof: XCTestCase {
	func testCancelOfflinePersistsAndAllowsFreshReviews() {
		ReviewRecoveryScreen.cancel(self, locked: false, dark: true)
	}

	func testCancelWithLockedCredentialPersistsAndAllowsFreshReviews() {
		ReviewRecoveryScreen.cancel(self, locked: true, dark: true)
	}
}

@MainActor
final class SavedReviewReadFailureProof: XCTestCase {
	func testApprovalButtonsDisableAndRestore() {
		ReviewRecoveryScreen.readFailure(self, layout: .approval, dark: false)
	}
	func testCheckAgainDisablesAndRestores() {
		ReviewRecoveryScreen.readFailure(self, layout: .checkAgain, dark: false)
	}
	func testRepeatApprovalButtonsDisableAndRestore() {
		ReviewRecoveryScreen.readFailure(self, layout: .repeatApproval, dark: false)
	}
	func testCancelOnlyDisablesAndRestores() {
		ReviewRecoveryScreen.readFailure(self, layout: .cancelOnly, dark: false)
	}
	func testReadOnlyReviewStaysWithoutButtons() {
		ReviewRecoveryScreen.readFailure(self, layout: .none, dark: false)
	}
}

@MainActor
final class SavedReviewReadFailureDarkProof: XCTestCase {
	func testApprovalButtonsDisableAndRestore() {
		ReviewRecoveryScreen.readFailure(self, layout: .approval, dark: true)
	}
	func testCheckAgainDisablesAndRestores() {
		ReviewRecoveryScreen.readFailure(self, layout: .checkAgain, dark: true)
	}
	func testRepeatApprovalButtonsDisableAndRestore() {
		ReviewRecoveryScreen.readFailure(self, layout: .repeatApproval, dark: true)
	}
	func testCancelOnlyDisablesAndRestores() {
		ReviewRecoveryScreen.readFailure(self, layout: .cancelOnly, dark: true)
	}
	func testReadOnlyReviewStaysWithoutButtons() {
		ReviewRecoveryScreen.readFailure(self, layout: .none, dark: true)
	}
}

@MainActor
enum ReviewRecoveryScreen {
	static let cancelled = "Cancelled. This workout may still have been saved. Check your calendar."
	static let unavailable =
		"Couldn't read the saved workout review. Its buttons are temporarily disabled."
	static let pending = "This workout may have been saved. Check the calendar before continuing."

	enum Layout: String {
		case approval, checkAgain, repeatApproval, cancelOnly, none

		var buttons: [String: String] {
			switch self {
			case .approval:
				["chat.preview.cancel": "Cancel", "chat.preview.add": "Add to calendar"]
			case .checkAgain: ["chat.preview.checkAgain": "Check again"]
			case .repeatApproval:
				[
					"chat.preview.checkAgain": "Check again", "chat.preview.cancel": "Cancel",
					"chat.preview.saveAgain": "Save approved workout again",
				]
			case .cancelOnly: ["chat.preview.cancel": "Cancel"]
			case .none: [:]
			}
		}
	}

	static func cancel(_ test: XCTestCase, locked: Bool, dark: Bool) {
		let app = unknownSave()
		TutorialHarness.relaunchKeepingStore(app)
		assertButtons(app, .checkAgain, enabled: true)
		TutorialHarness.named(app, "chat.preview.checkAgain").tap()
		assertButtons(app, .repeatApproval, enabled: true)
		control(app, locked ? "fixture.lockIntervals" : "fixture.failCalendarRead")
		let before = calendarCalls(app)
		TutorialHarness.named(app, "chat.preview.cancel").tap()
		assertNote(app)
		assertButtons(app, .none, enabled: true)
		XCTAssertFalse(app.staticTexts["Workout review"].exists)
		XCTAssertEqual(calendarCalls(app), before, "Cancel made a calendar request")
		if !locked {
			TutorialHarness.openDebug(app)
			let fault = TutorialHarness.debugRow(app, "fixture.calendarReadFault")
			TutorialHarness.wait(
				until: { fault.label == "Calendar read fault armed" },
				message: "Calendar read fault was consumed by Cancel")
			TutorialHarness.returnToChat(app)
		}
		capture(test, app, name: locked ? "cancel-locked" : "cancel-offline", dark: dark)
		TutorialHarness.relaunchKeepingStore(app, keychain: .unlocked)
		assertNote(app)
		assertButtons(app, .none, enabled: true)
		XCTAssertFalse(app.staticTexts["Workout review"].exists)
		capture(test, app, name: "cancel-reopened", dark: dark)
		TutorialHarness.exchange(app, TutorialHarness.workout)
		assertButtons(app, .approval, enabled: true)
		assertNote(app)
		capture(test, app, name: "cancel-fresh-review", dark: dark)
		TutorialHarness.named(app, "chat.preview.cancel").tap()
		assertButtons(app, .none, enabled: true)
		TutorialHarness.startNewConversation(app)
		TutorialHarness.waitForWelcome(app)
		TutorialHarness.exchange(app, TutorialHarness.workout)
		assertButtons(app, .approval, enabled: true)
		XCTAssertEqual(textCount(app, cancelled), 0)
		capture(test, app, name: "cancel-fresh-new-conversation", dark: dark)
		TutorialHarness.openHistory(app)
		let row = TutorialHarness.historyRows(app).firstMatch
		TutorialHarness.wait(row, until: .hittable)
		row.tap()
		TutorialHarness.waitForLabel(app, cancelled)
		XCTAssertEqual(textCount(app, cancelled), 1)
		let archive = TutorialHarness.named(app, "archive.content")
		TutorialHarness.wait(archive)
		assertButtons(archive, .none, enabled: true)
		capture(test, app, name: "cancel-history-note", dark: dark)
	}

	static func readFailure(_ test: XCTestCase, layout: Layout, dark: Bool) {
		let app: XCUIApplication
		switch layout {
		case .none:
			app = XCUIApplication()
			TutorialHarness.launchUpgrade(app, store: .v1Review)
		case .approval:
			app = XCUIApplication()
			TutorialHarness.launch(
				app, arguments: FixtureArguments(recordReadFault: .failAfterPresentedOnce))
			TutorialHarness.completeOnboarding(app)
			TutorialHarness.exchange(app, TutorialHarness.workout)
		default:
			app = unknownSave()
			TutorialHarness.relaunchKeepingStore(app)
			assertButtons(app, .checkAgain, enabled: true)
			if layout == .repeatApproval {
				TutorialHarness.named(app, "chat.preview.checkAgain").tap()
			} else if layout == .cancelOnly {
				control(app, "fixture.switchAthlete")
			}
		}
		if layout != .approval {
			assertButtons(app, layout, enabled: true)
			control(app, "fixture.failReviewRead")
		}
		TutorialHarness.waitForIdentifier(app, "chat.preview.notice", reading: unavailable)
		assertButtons(app, layout, enabled: false)
		XCTAssertEqual(textCount(app, unavailable), 1)
		XCTAssertEqual(textCount(app, "Sorry, something went wrong. Please try again."), 0)
		TutorialHarness.wait(TutorialHarness.named(app, "chat.preview.retryRead"), until: .enabled)
		let before = calendarCalls(app)
		let modelBefore = modelRequests(app)
		for id in layout.buttons.keys {
			let button = TutorialHarness.named(app, id)
			TutorialHarness.wait(button, until: .hittable)
			button.tap()
		}
		assertButtons(app, layout, enabled: false)
		XCTAssertEqual(calendarCalls(app), before, "A disabled review button sent an intent")
		control(app, "fixture.failReviewRead")
		TutorialHarness.waitForIdentifier(app, "chat.preview.notice", reading: unavailable)
		assertButtons(app, layout, enabled: false)
		XCTAssertEqual(textCount(app, unavailable), 1)
		capture(test, app, name: "review-unreadable-" + layout.rawValue, dark: dark)
		TutorialHarness.named(app, "chat.preview.retryRead").tap()
		TutorialHarness.wait(
			until: { textCount(app, unavailable) == 0 },
			message: "Successful read did not clear the unavailable line")
		assertButtons(app, layout, enabled: true)
		XCTAssertEqual(textCount(app, unavailable), 0)
		XCTAssertEqual(
			calendarCalls(app), before, "Restoring saved controls requested the calendar")
		XCTAssertEqual(
			modelRequests(app), modelBefore, "Restoring saved controls requested the model")
		capture(test, app, name: "review-restored-" + layout.rawValue, dark: dark)
	}

	static func unknownSave() -> XCUIApplication {
		let app = XCUIApplication()
		TutorialHarness.launch(app, arguments: FixtureArguments(calendarSaveFault: .loseAnswerOnce))
		TutorialHarness.completeOnboarding(app)
		TutorialHarness.exchange(app, TutorialHarness.workout)
		assertButtons(app, .approval, enabled: true)
		TutorialHarness.named(app, "chat.preview.add").tap()
		TutorialHarness.waitForIdentifier(app, "chat.preview.notice", reading: pending)
		assertButtons(app, .checkAgain, enabled: true)
		return app
	}

	static func assertButtons(_ container: XCUIElement, _ layout: Layout, enabled: Bool) {
		let controls = container.buttons.matching(
			NSPredicate(format: "identifier BEGINSWITH %@", "chat.preview."))
		var expected = layout.buttons
		if !enabled { expected["chat.preview.retryRead"] = "Retry" }
		TutorialHarness.wait(
			until: {
				controls.count == expected.count
					&& controls.allElementsBoundByIndex.allSatisfy {
						expected[$0.identifier] == $0.label
							&& $0.isEnabled
								== (enabled || $0.identifier == "chat.preview.retryRead")
					}
			}, message: "The review did not reach its exact button layout")
		XCTAssertEqual(Set(controls.allElementsBoundByIndex.map(\.identifier)), Set(expected.keys))
		XCTAssertEqual(
			Set(controls.allElementsBoundByIndex.filter(\.isEnabled).map(\.identifier)),
			enabled ? Set(expected.keys) : ["chat.preview.retryRead"])
		XCTAssertFalse(container.buttons["Try again"].exists)
	}

	private static func assertNote(_ app: XCUIApplication) {
		TutorialHarness.waitForIdentifier(app, "chat.note", reading: cancelled)
		XCTAssertEqual(textCount(app, cancelled), 1)
	}

	private static func textCount(_ app: XCUIApplication, _ text: String) -> Int {
		app.staticTexts.matching(NSPredicate(format: "label == %@", text)).count
	}

	private static func control(_ app: XCUIApplication, _ id: String) {
		TutorialHarness.fixtureControl(app, id)
	}

	static func calendarCalls(_ app: XCUIApplication) -> String {
		TutorialHarness.openDebug(app)
		let count = TutorialHarness.debugRow(app, "fixture.calendarCalls")
		let value = count.label
		TutorialHarness.returnToChat(app)
		return value
	}

	static func modelRequests(_ app: XCUIApplication) -> String {
		TutorialHarness.openDebug(app)
		let value = TutorialHarness.debugRow(app, "fixture.modelRequestCount").label
		TutorialHarness.returnToChat(app)
		return value
	}

	private static func capture(
		_ test: XCTestCase, _ app: XCUIApplication, name: String, dark: Bool
	) {
		TutorialHarness.attach(test, name: name + (dark ? "-dark" : "-light"), app: app)
		let luminance = TutorialHarness.meanLuminance(app.screenshot())
		if dark { XCTAssertLessThan(luminance, 0.4) } else { XCTAssertGreaterThan(luminance, 0.4) }
	}
}
