import XCTest

final class ConfirmedPreviewProof: XCTestCase {
	func testConfirmedPreview() {
		let app = XCUIApplication()
		TutorialHarness.launch(app)
		TutorialHarness.completeOnboarding(app)
		TutorialHarness.exchange(app, TutorialHarness.workout)
		let cancel = TutorialHarness.named(app, "chat.preview.cancel")
		let add = TutorialHarness.named(app, "chat.preview.add")
		TutorialHarness.wait(add, until: .enabled)
		TutorialHarness.waitForLabel(app, "Workout review")
		TutorialHarness.waitForLabel(app, TutorialHarness.warmup)
		XCTAssertTrue(cancel.isEnabled)
		XCTAssertLessThan(cancel.frame.minX, add.frame.minX)
		TutorialHarness.attach(self, name: "07-confirmed-preview", app: app)
	}
}

final class AddedToCalendarProof: XCTestCase {
	func testAddedToCalendar() {
		let app = XCUIApplication()
		TutorialHarness.launch(app)
		TutorialHarness.completeOnboarding(app)
		TutorialHarness.exchange(app, TutorialHarness.workout)
		let add = TutorialHarness.named(app, "chat.preview.add")
		TutorialHarness.wait(add, until: .enabled)
		let tapped = Date()
		add.tap()
		let done = app.staticTexts[TutorialHarness.done]
		TutorialHarness.wait(done, within: .screen)
		let sample = XCTAttachment(
			string: String(format: "%.0f", Date().timeIntervalSince(tapped) * 1_000))
		sample.name = "add-to-done-ms"
		sample.lifetime = .keepAlways
		self.add(sample)
		TutorialHarness.waitForLabel(app, TutorialHarness.done)
		TutorialHarness.attach(self, name: "07b-added-to-calendar", app: app)
	}
}

final class ConfirmedPreviewDarkProof: XCTestCase {
	func testConfirmedPreviewDark() {
		let app = XCUIApplication()
		TutorialHarness.launch(app)
		TutorialHarness.completeOnboarding(app)
		TutorialHarness.exchange(app, TutorialHarness.workout)
		TutorialHarness.wait(TutorialHarness.named(app, "chat.preview.add"), until: .enabled)
		TutorialHarness.waitForLabel(app, "Workout review")
		let screenshot = app.screenshot()
		TutorialHarness.attach(self, name: "07-confirmed-preview-dark", app: app)
		XCTAssertLessThan(
			TutorialHarness.meanLuminance(screenshot), 0.4, "the capture is not in dark appearance")
	}
}

final class PreviewCancelStaysGoneProof: XCTestCase {
	func testPreviewCancelStaysGone() {
		let app = XCUIApplication()
		TutorialHarness.launch(app)
		TutorialHarness.completeOnboarding(app)
		TutorialHarness.exchange(app, TutorialHarness.workout)
		let cancel = TutorialHarness.named(app, "chat.preview.cancel")
		TutorialHarness.wait(cancel, until: .enabled)
		TutorialHarness.attach(self, name: "preview-before-cancel", app: app)
		cancel.tap()
		TutorialHarness.wait(TutorialHarness.named(app, "chat.preview.add"), until: .absent)
		TutorialHarness.exchange(app, TutorialHarness.saturday)
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
		TutorialHarness.exchange(app, TutorialHarness.workout)
		let add = TutorialHarness.named(app, "chat.preview.add")
		TutorialHarness.wait(add, until: .enabled)
		add.tap()
		TutorialHarness.waitForLabel(app, TutorialHarness.done)
		TutorialHarness.attach(self, name: "done-before-relaunch", app: app)
		TutorialHarness.relaunchKeepingStore(app)
		TutorialHarness.waitForLabel(app, TutorialHarness.done)
		XCTAssertFalse(TutorialHarness.named(app, "chat.preview.add").exists)
		TutorialHarness.attach(self, name: "done-after-relaunch", app: app)
	}
}

final class ExpiredReviewProof: XCTestCase {
	func testAReviewPastTenMinutesIsGoneAfterRelaunchWithNoWrite() {
		let app = XCUIApplication()
		TutorialHarness.launch(app)
		TutorialHarness.completeOnboarding(app)
		TutorialHarness.exchange(app, TutorialHarness.workout)
		let add = TutorialHarness.named(app, "chat.preview.add")
		TutorialHarness.wait(add, until: .enabled)
		TutorialHarness.attach(self, name: "review-before-expiry", app: app)
		TutorialHarness.relaunchKeepingStore(app, clock: "1998-06-15T08:11:00Z")
		TutorialHarness.waitForLabel(app, TutorialHarness.workout)
		XCTAssertFalse(add.exists)
		XCTAssertFalse(TutorialHarness.named(app, "chat.preview.cancel").exists)
		XCTAssertFalse(app.staticTexts[TutorialHarness.done].exists)
		TutorialHarness.attach(self, name: "review-expired-after-relaunch", app: app)
		TutorialHarness.openRecords(app)
		TutorialHarness.waitForRecordCount(app, "pendingProposal", "pendingProposal 1")
		XCTAssertNil(TutorialHarness.recordCount(app, "proposalCleared"))
		XCTAssertNil(TutorialHarness.recordCount(app, "reviewApplied"))
		TutorialHarness.attach(self, name: "review-expired-records", app: app)
	}
}

final class LegacyReviewNoticeProof: XCTestCase {
	static let english =
		"This workout review is from an earlier version of the app and can no longer be applied."
	static let german =
		"Diese Trainingsprüfung stammt aus einer früheren Version der App und kann nicht mehr angewendet werden."

	func testV1ReviewIsReadOnlyDisconnectedConnectedAndInGerman() throws {
		let app = XCUIApplication()
		TutorialHarness.launchUpgrade(app, store: .v1Review)
		TutorialHarness.openCredentials(app)
		XCTAssertFalse(TutorialHarness.named(app, "training.athlete").exists)
		TutorialHarness.returnToChat(app)
		assertReadOnly(app, reading: Self.english)
		TutorialHarness.attach(self, name: "v1-review-disconnected", app: app)
		TutorialHarness.openCredentials(app)
		TutorialHarness.named(app, "training.edit").tap()
		TutorialHarness.type(app, "fixture", into: "training.apiKey")
		TutorialHarness.named(app, "training.save").tap()
		TutorialHarness.waitForIdentifier(app, "training.athlete", reading: "Ada Kovač")
		TutorialHarness.returnToChat(app)
		assertReadOnly(app, reading: Self.english)
		TutorialHarness.attach(self, name: "v1-review-connected", app: app)
		assertNothingWritten(app, attaching: "v1-review-records")
		TutorialHarness.relaunchKeepingStore(app, language: "de", locale: "de_DE")
		assertReadOnly(app, reading: Self.german)
		TutorialHarness.attach(self, name: "v1-review-german", app: app)
		assertNothingWritten(app, attaching: "v1-review-german-records")
	}

	private func assertReadOnly(_ app: XCUIApplication, reading sentence: String) {
		TutorialHarness.waitForIdentifier(app, "chat.preview.notice", reading: sentence)
		XCTAssertFalse(TutorialHarness.named(app, "chat.preview.add").exists)
		XCTAssertFalse(TutorialHarness.named(app, "chat.preview.cancel").exists)
	}

	private func assertNothingWritten(_ app: XCUIApplication, attaching name: String) {
		TutorialHarness.openRecords(app)
		TutorialHarness.waitForRecordCount(app, "pendingProposal", "pendingProposal 1")
		XCTAssertNil(TutorialHarness.recordCount(app, "proposalCleared"))
		XCTAssertNil(TutorialHarness.recordCount(app, "reviewApplied"))
		TutorialHarness.attach(self, name: name, app: app)
		TutorialHarness.returnToChat(app)
	}
}
