import XCTest

@MainActor
final class UnknownCalendarSaveProof: XCTestCase {
	func testUnknownSaveOffersOnlyCheckAgain() {
		UnknownCalendarSaveScreen.unknown(self, dark: false)
	}

	func testAbsentReadOffersOnlyCheckCancelAndSaveAgain() {
		UnknownCalendarSaveScreen.absent(self, dark: false)
	}

	func testFailedCheckAgainKeepsCheckAgainInTheSameSession() {
		UnknownCalendarSaveScreen.failedRead(self, dark: false)
	}

	func testNeverApprovedCardDoesNotClaimAnApprovedSaveIsPending() {
		UnknownCalendarSaveScreen.neverApproved(self, dark: false)
	}
}

@MainActor
final class UnknownCalendarSaveDarkProof: XCTestCase {
	func testUnknownSaveOffersOnlyCheckAgain() {
		UnknownCalendarSaveScreen.unknown(self, dark: true)
	}

	func testAbsentReadOffersOnlyCheckCancelAndSaveAgain() {
		UnknownCalendarSaveScreen.absent(self, dark: true)
	}

	func testFailedCheckAgainKeepsCheckAgainInTheSameSession() {
		UnknownCalendarSaveScreen.failedRead(self, dark: true)
	}

	func testNeverApprovedCardDoesNotClaimAnApprovedSaveIsPending() {
		UnknownCalendarSaveScreen.neverApproved(self, dark: true)
	}
}

@MainActor
private enum UnknownCalendarSaveScreen {
	static let pending =
		"This workout may have been saved. Check the calendar before continuing."
	static let readFailed =
		"The calendar could not be checked. Your approved workout is still pending."
	static let check = ["chat.preview.checkAgain": "Check again"]
	static let repeatApproval = [
		"chat.preview.checkAgain": "Check again", "chat.preview.cancel": "Cancel",
		"chat.preview.saveAgain": "Save approved workout again",
	]
	static let approval = ["chat.preview.cancel": "Cancel", "chat.preview.add": "Add to calendar"]

	static func unknown(_ test: XCTestCase, dark: Bool) {
		let app = unknownSave()
		assertCard(app, pendingCount: 1, failedCount: 0, buttons: check)
		capture(test, app, name: "calendar-unknown", dark: dark)
	}

	static func absent(_ test: XCTestCase, dark: Bool) {
		let app = unknownSave()
		reopen(app)
		assertCard(app, pendingCount: 1, failedCount: 0, buttons: check)
		TutorialHarness.named(app, "chat.preview.checkAgain").tap()
		assertCard(app, pendingCount: 1, failedCount: 0, buttons: repeatApproval)
		capture(test, app, name: "calendar-absent", dark: dark)
	}

	static func failedRead(_ test: XCTestCase, dark: Bool) {
		let app = unknownSave()
		reopen(app, failRead: true)
		assertCard(app, pendingCount: 1, failedCount: 0, buttons: check)
		TutorialHarness.named(app, "chat.preview.checkAgain").tap()
		assertCard(app, pendingCount: 0, failedCount: 1, buttons: check)
		capture(test, app, name: "calendar-check-failed", dark: dark)
		TutorialHarness.named(app, "chat.preview.checkAgain").tap()
		assertCard(app, pendingCount: 1, failedCount: 0, buttons: repeatApproval)
		capture(test, app, name: "calendar-check-recovered", dark: dark)
	}

	static func neverApproved(_ test: XCTestCase, dark: Bool) {
		let app = XCUIApplication()
		TutorialHarness.launch(app)
		TutorialHarness.completeOnboarding(app)
		TutorialHarness.exchange(app, TutorialHarness.workout)
		assertCard(app, pendingCount: 0, failedCount: 0, buttons: approval)
		capture(test, app, name: "calendar-never-approved", dark: dark)
		TutorialHarness.relaunchKeepingStore(app, keychain: .locked)
		assertCard(app, pendingCount: 0, failedCount: 0, buttons: approval)
		capture(test, app, name: "calendar-never-approved-locked", dark: dark)
	}

	private static func unknownSave() -> XCUIApplication {
		let app = XCUIApplication()
		TutorialHarness.launch(
			app, arguments: FixtureArguments(calendarSaveFault: .loseAnswerOnce))
		TutorialHarness.completeOnboarding(app)
		TutorialHarness.exchange(app, TutorialHarness.workout)
		let add = TutorialHarness.named(app, "chat.preview.add")
		TutorialHarness.wait(add, until: .enabled)
		TutorialHarness.wait(add, until: .hittable)
		add.tap()
		TutorialHarness.waitForIdentifier(app, "chat.preview.notice", reading: pending)
		return app
	}

	private static func reopen(_ app: XCUIApplication, failRead: Bool = false) {
		app.terminate()
		XCTAssertEqual(app.state, .notRunning)
		TutorialHarness.launch(
			app,
			arguments: FixtureArguments(
				store: .keep, calendarReadFault: failRead ? .failOnce : nil))
	}

	private static func assertCard(
		_ app: XCUIApplication, pendingCount: Int, failedCount: Int, buttons: [String: String]
	) {
		let controls = app.buttons.matching(
			NSPredicate(format: "identifier BEGINSWITH %@", "chat.preview."))
		TutorialHarness.wait(
			until: {
				app.staticTexts.matching(NSPredicate(format: "label == %@", pending)).count
					== pendingCount
					&& app.staticTexts.matching(NSPredicate(format: "label == %@", readFailed))
						.count
						== failedCount
					&& controls.count == buttons.count
					&& controls.allElementsBoundByIndex.allSatisfy {
						buttons[$0.identifier] == $0.label && $0.isEnabled
					}
			}, message: "the calendar review did not reach the exact notice and button set")
		XCTAssertEqual(
			app.staticTexts.matching(NSPredicate(format: "label == %@", pending)).count,
			pendingCount)
		XCTAssertEqual(
			app.staticTexts.matching(NSPredicate(format: "label == %@", readFailed)).count,
			failedCount)
		XCTAssertEqual(controls.count, buttons.count)
		XCTAssertEqual(
			Set(controls.allElementsBoundByIndex.map { $0.identifier }), Set(buttons.keys))
		XCTAssertEqual(Set(controls.allElementsBoundByIndex.map { $0.label }), Set(buttons.values))
		XCTAssertFalse(app.buttons["Try again"].exists)
		for identifier in buttons.keys {
			TutorialHarness.wait(TutorialHarness.named(app, identifier), until: .hittable)
		}
		if pendingCount == 1 {
			TutorialHarness.wait(app.staticTexts[pending], until: .hittable)
		}
		if failedCount == 1 {
			TutorialHarness.wait(app.staticTexts[readFailed], until: .hittable)
		}
	}

	private static func capture(
		_ test: XCTestCase, _ app: XCUIApplication, name: String, dark: Bool
	) {
		TutorialHarness.attach(test, name: name + (dark ? "-dark" : "-light"), app: app)
		let luminance = TutorialHarness.meanLuminance(app.screenshot())
		if dark {
			XCTAssertLessThan(luminance, 0.4, "the capture is not in dark appearance")
		} else {
			XCTAssertGreaterThan(luminance, 0.4, "the capture is not in light appearance")
		}
	}
}
