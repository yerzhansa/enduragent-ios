import XCTest

@MainActor
final class UnknownCalendarSaveProof: XCTestCase {
	func testUnknownSaveOffersOnlyCheckAgain() {
		UnknownCalendarSaveScreen.unknown(self)
	}

	func testAbsentReadOffersOnlyCheckCancelAndSaveAgain() {
		UnknownCalendarSaveScreen.absent(self)
	}

	func testFailedCheckAgainKeepsCheckAgainInTheSameSession() {
		UnknownCalendarSaveScreen.failedRead(self)
	}

	func testNeverApprovedCardDoesNotClaimAnApprovedSaveIsPending() {
		UnknownCalendarSaveScreen.neverApproved(self)
	}
}

@MainActor
private enum UnknownCalendarSaveScreen {
	static let pending =
		"This workout may have been saved. Check the calendar before continuing."
	static let readFailed =
		"The calendar could not be checked. Your approved workout is still pending."
	static let cannotVerify =
		"Couldn't check your intervals.icu connection, so nothing was changed. Try again in a moment."
	static let check = ["chat.preview.checkAgain": "Check again"]
	static let repeatApproval = [
		"chat.preview.checkAgain": "Check again", "chat.preview.cancel": "Cancel",
		"chat.preview.saveAgain": "Save approved workout again",
	]
	static let approval = ["chat.preview.cancel": "Cancel", "chat.preview.add": "Add to calendar"]

	static func unknown(_ test: XCTestCase) {
		let app = unknownSave()
		assertCard(app, pendingCount: 1, failedCount: 0, buttons: check)
		capture(test, app, name: "calendar-unknown")
	}

	static func absent(_ test: XCTestCase) {
		let app = unknownSave()
		reopen(app)
		assertCard(app, pendingCount: 1, failedCount: 0, buttons: check)
		TutorialHarness.named(app, "chat.preview.checkAgain").tap()
		assertCard(app, pendingCount: 1, failedCount: 0, buttons: repeatApproval)
		capture(test, app, name: "calendar-absent")
	}

	static func failedRead(_ test: XCTestCase) {
		let app = unknownSave()
		reopen(app, failRead: true)
		assertCard(app, pendingCount: 1, failedCount: 0, buttons: check)
		TutorialHarness.named(app, "chat.preview.checkAgain").tap()
		assertCard(app, pendingCount: 0, failedCount: 1, buttons: check)
		capture(test, app, name: "calendar-check-failed")
		TutorialHarness.named(app, "chat.preview.checkAgain").tap()
		assertCard(app, pendingCount: 1, failedCount: 0, buttons: repeatApproval)
		capture(test, app, name: "calendar-check-recovered")
	}

	static func neverApproved(_ test: XCTestCase) {
		let app = XCUIApplication()
		TutorialHarness.launch(app)
		TutorialHarness.completeOnboarding(app)
		TutorialHarness.exchange(app, TutorialHarness.workout)
		assertCard(app, pendingCount: 0, failedCount: 0, buttons: approval)
		capture(test, app, name: "calendar-never-approved")
		TutorialHarness.relaunchKeepingStore(app, keychain: .locked)
		TutorialHarness.waitForIdentifier(app, "chat.preview.notice", reading: cannotVerify)
		assertCard(app, pendingCount: 0, failedCount: 0, buttons: [:])
		capture(test, app, name: "calendar-never-approved-locked")
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

	private static func capture(_ test: XCTestCase, _ app: XCUIApplication, name: String) {
		TutorialHarness.attach(test, name: name + "-light", app: app)
		let luminance = TutorialHarness.meanLuminance(app.screenshot())
		XCTAssertGreaterThan(luminance, 0.4, "the capture is not in light appearance")
	}
}
