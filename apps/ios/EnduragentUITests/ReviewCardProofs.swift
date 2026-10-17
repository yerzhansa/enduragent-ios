import XCTest

@MainActor
final class ReviewUpgradeProof: XCTestCase {
	static let askAgain =
		"This review was prepared before the app was updated. Ask the coach again."

	func testAnOpenReviewAsksTheCoachAgainOfflineAndOnline() {
		let app = XCUIApplication()
		launchOffline(app, store: .openReviewBeforeUpgrade)
		assertClosed(app)
		TutorialHarness.attach(self, name: "u9-2-upgrade-open-review-offline", app: app)
		TutorialHarness.relaunchKeepingStore(app)
		assertClosed(app)
		TutorialHarness.attach(self, name: "u9-2-upgrade-open-review-online", app: app)
	}

	func testAnUnknownWriteOpensUnconfirmedOfflineAndSettlesOnline() {
		let app = XCUIApplication()
		launchOffline(app, store: .unknownWriteBeforeUpgrade)
		TutorialHarness.waitForLabel(app, "Workout review")
		ReviewCardScreen.assertButtons(app, .checkAgainOrCancel)
		TutorialHarness.attach(self, name: "u9-2-upgrade-unknown-write-offline", app: app)
		TutorialHarness.relaunchKeepingStore(app)
		ReviewCardScreen.assertButtons(app, .tryAgainOrCancel)
		TutorialHarness.attach(self, name: "u9-2-upgrade-unknown-write-online", app: app)
		TutorialHarness.named(app, "chat.preview.tryAgain").tap()
		TutorialHarness.wait(
			TutorialHarness.text(app, containing: "Endurance with tempo, 6/16/1998: change saved."))
		ReviewCardScreen.assertButtons(app, .none)
		TutorialHarness.attach(self, name: "u9-2-upgrade-unknown-write-saved", app: app)
	}

	func testTheCompletedScenarioKeepsItsNoteWithNoControl() {
		let app = XCUIApplication()
		TutorialHarness.launchUpgrade(app, store: .completedBeforeUpgrade)
		let note = TutorialHarness.named(app, "chat.note")
		TutorialHarness.wait(note)
		XCTAssertTrue(note.label.contains("Endurance with tempo"), note.label)
		ReviewCardScreen.assertButtons(app, .none)
		XCTAssertFalse(app.staticTexts["Workout review"].exists)
		TutorialHarness.attach(self, name: "u9-2-upgrade-completed", app: app)
	}

	private func launchOffline(_ app: XCUIApplication, store: FixtureStorePolicy) {
		TutorialHarness.launch(
			app,
			arguments: FixtureArguments(store: store, onboarded: true, calendarReadFault: .failOnce)
		)
		TutorialHarness.agreeToProviderConsent(app)
	}

	private func assertClosed(_ app: XCUIApplication) {
		TutorialHarness.waitForIdentifier(app, "chat.note", reading: Self.askAgain)
		XCTAssertEqual(
			app.staticTexts.matching(identifier: "chat.note").matching(
				NSPredicate(format: "label == %@", Self.askAgain)
			).count, 1)
		ReviewCardScreen.assertButtons(app, .none)
		XCTAssertFalse(app.staticTexts["Workout review"].exists)
	}
}

@MainActor
final class ReviewStorageNoticeProof: XCTestCase {
	func testAReviewThatCannotBeReadShowsTheStorageNoticeWithItsButtonsDisabled() {
		let app = XCUIApplication()
		TutorialHarness.launch(
			app, arguments: FixtureArguments(recordReadFault: .failAfterPresentedOnce))
		TutorialHarness.completeOnboarding(app)
		TutorialHarness.exchange(app, TutorialHarness.workout)
		TutorialHarness.waitForIdentifier(
			app, "chat.preview.notice",
			reading: "Couldn't read the saved workout review. Its buttons are temporarily disabled."
		)
		let enabled = app.buttons.matching(
			NSPredicate(format: "identifier BEGINSWITH %@ AND enabled == YES", "chat.preview."))
		XCTAssertEqual(enabled.count, 0, "a review that cannot be read offered a control")
		TutorialHarness.attach(self, name: "u9-2-review-storage-notice", app: app)
		TutorialHarness.relaunchKeepingStore(app)
		ReviewCardScreen.assertButtons(app, .approveOrCancel)
		XCTAssertFalse(TutorialHarness.named(app, "chat.preview.notice").exists)
		TutorialHarness.attach(self, name: "u9-2-review-storage-notice-cleared", app: app)
	}
}

@MainActor
final class ReviewLostAnswerProof: XCTestCase {
	func testALostAnswerIsReadAtOnceAndSeenOnTheCalendar() {
		let app = XCUIApplication()
		TutorialHarness.launch(app, arguments: FixtureArguments(calendarSaveFault: .loseAnswerOnce))
		TutorialHarness.completeOnboarding(app)
		TutorialHarness.exchange(app, TutorialHarness.workout)
		ReviewCardScreen.assertButtons(app, .approveOrCancel)
		TutorialHarness.named(app, "chat.preview.add").tap()
		TutorialHarness.wait(
			TutorialHarness.text(
				app, containing: "Endurance with tempo, 6/16/1998: change seen on the calendar."))
		ReviewCardScreen.assertButtons(app, .none)
		XCTAssertFalse(app.staticTexts["Workout review"].exists)
		TutorialHarness.attach(self, name: "u9-2-review-lost-answer-seen", app: app)
	}
}
