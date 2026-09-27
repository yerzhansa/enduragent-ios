import XCTest

final class ConfirmedPreviewProof: XCTestCase {
	func testConfirmedPreview() {
		let app = XCUIApplication()
		TutorialHarness.launch(app)
		TutorialHarness.completeOnboarding(app)
		TutorialHarness.send(app, TutorialHarness.workout)
		let cancel = TutorialHarness.named(app, "chat.preview.cancel")
		let add = TutorialHarness.named(app, "chat.preview.add")
		TutorialHarness.waitUntilEnabled(add)
		TutorialHarness.waitForLabel(app, "Workout review")
		TutorialHarness.waitForLabel(app, TutorialHarness.warmup)
		XCTAssertTrue(cancel.isEnabled)
		XCTAssertLessThan(cancel.frame.minX, add.frame.minX)
		TutorialHarness.attach(self, name: "07-confirmed-preview", app: app)
		TutorialHarness.assertZeroFixtureRequests(app)
	}
}

final class AddedToCalendarProof: XCTestCase {
	func testAddedToCalendar() {
		let app = XCUIApplication()
		TutorialHarness.launch(app)
		TutorialHarness.completeOnboarding(app)
		TutorialHarness.send(app, TutorialHarness.workout)
		let add = TutorialHarness.named(app, "chat.preview.add")
		TutorialHarness.waitUntilEnabled(add)
		let tapped = Date()
		add.tap()
		let done = app.staticTexts[TutorialHarness.done]
		while !done.exists, Date().timeIntervalSince(tapped) < 10 {
			continue
		}
		let sample = XCTAttachment(
			string: String(format: "%.0f", Date().timeIntervalSince(tapped) * 1_000))
		sample.name = "add-to-done-ms"
		sample.lifetime = .keepAlways
		self.add(sample)
		TutorialHarness.waitForLabel(app, TutorialHarness.done)
		TutorialHarness.attach(self, name: "07b-added-to-calendar", app: app)
		TutorialHarness.assertZeroFixtureRequests(app)
	}
}

final class ConfirmedPreviewDarkProof: XCTestCase {
	func testConfirmedPreviewDark() {
		let app = XCUIApplication()
		addTeardownBlock { XCUIDevice.shared.appearance = .light }
		TutorialHarness.launch(app, dark: true)
		TutorialHarness.completeOnboarding(app)
		TutorialHarness.send(app, TutorialHarness.workout)
		TutorialHarness.waitUntilEnabled(TutorialHarness.named(app, "chat.preview.add"))
		TutorialHarness.waitForLabel(app, "Workout review")
		let screenshot = app.screenshot()
		TutorialHarness.attach(self, name: "07-confirmed-preview-dark", app: app)
		XCTAssertLessThan(
			TutorialHarness.meanLuminance(screenshot), 0.4, "the capture is not in dark appearance")
		TutorialHarness.assertZeroFixtureRequests(app)
	}
}

final class PreviewCancelStaysGoneProof: XCTestCase {
	func testPreviewCancelStaysGone() {
		let app = XCUIApplication()
		TutorialHarness.launch(app)
		TutorialHarness.completeOnboarding(app)
		TutorialHarness.send(app, TutorialHarness.workout)
		let cancel = TutorialHarness.named(app, "chat.preview.cancel")
		TutorialHarness.waitUntilEnabled(cancel)
		TutorialHarness.attach(self, name: "preview-before-cancel", app: app)
		cancel.tap()
		TutorialHarness.waitForAbsence(TutorialHarness.named(app, "chat.preview.add"))
		TutorialHarness.send(app, TutorialHarness.saturday)
		TutorialHarness.waitForLabel(app, TutorialHarness.weekReply)
		XCTAssertFalse(TutorialHarness.named(app, "chat.preview.add").exists)
		XCTAssertFalse(app.staticTexts["Workout review"].exists)
		XCTAssertFalse(app.staticTexts[TutorialHarness.done].exists)
		TutorialHarness.attach(self, name: "preview-canceled-after-next-message", app: app)
		TutorialHarness.relaunchKeepingStore(app)
		TutorialHarness.waitForLabel(app, TutorialHarness.saturday)
		XCTAssertFalse(TutorialHarness.named(app, "chat.preview.add").exists)
		TutorialHarness.openRecords(app)
		TutorialHarness.waitForRecordCount(app, "proposalCleared", "proposalCleared 1")
		let clears = TutorialHarness.recordRowLabels(app).filter {
			$0.hasPrefix("proposalCleared")
		}
		XCTAssertEqual(clears.count, 1)
		XCTAssertTrue(
			clears.allSatisfy { $0.hasPrefix("proposalCleared canceled ") }, "\(clears)")
		TutorialHarness.attach(self, name: "preview-canceled-records", app: app)
	}
}

final class DoneLineSurvivesRelaunchProof: XCTestCase {
	func testDoneLineSurvivesRelaunch() {
		let app = XCUIApplication()
		TutorialHarness.launch(app)
		TutorialHarness.completeOnboarding(app)
		TutorialHarness.send(app, TutorialHarness.workout)
		let add = TutorialHarness.named(app, "chat.preview.add")
		TutorialHarness.waitUntilEnabled(add)
		add.tap()
		TutorialHarness.waitForLabel(app, TutorialHarness.done)
		TutorialHarness.attach(self, name: "done-before-relaunch", app: app)
		TutorialHarness.relaunchKeepingStore(app)
		TutorialHarness.waitForLabel(app, TutorialHarness.done)
		XCTAssertFalse(TutorialHarness.named(app, "chat.preview.add").exists)
		TutorialHarness.attach(self, name: "done-after-relaunch", app: app)
		TutorialHarness.assertZeroFixtureRequests(app)
	}
}
