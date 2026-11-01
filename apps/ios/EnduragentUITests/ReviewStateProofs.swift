import EnduragentCoach
import XCTest

@MainActor
enum ReviewStates {
	static let firstAdd = "Endurance 50, 6/16/1998"
	static let secondAdd = "Core strength, 6/17/1998"
	static let edit = "Endurance, 6/18/1998"
	static let delete = "Recovery spin, 6/19/1998"
	static let partial =
		"intervals.icu refused a change, so the remaining changes were stopped. Changes already made are kept. Check the rest before you try again."
	static let unconfirmed =
		"A change may have been saved to your intervals.icu calendar. Check again to find out before anything else is changed."
	static let stopped =
		"This workout review stopped before every change was made. Changes already made are kept."
	static let sending = "Making the reviewed changes on your intervals.icu calendar…"
	static let refreshed =
		"Workouts in this review changed in intervals.icu after you reviewed them, so nothing was changed. Check them again before you approve."
	static let refreshedDuration = "Endurance: duration changed from 60 to 90 minutes."
	static let missing =
		"A workout in this review is no longer on your intervals.icu calendar, so this review can't continue. Cancel it and ask the coach again."
	static let storage =
		"Couldn't read the saved workout review. Its buttons are temporarily disabled."
	static let completed = "All reviewed changes are complete."
	static let canceled = "The remaining changes were canceled."

	static func arrive(at stage: FixtureReviewStage) -> XCUIApplication {
		let app = XCUIApplication()
		TutorialHarness.launch(app, arguments: FixtureArguments(reviewStage: stage))
		TutorialHarness.completeOnboarding(app)
		TutorialHarness.exchange(app, ReviewCardContent.mixed)
		TutorialHarness.wait(ReviewCardScreen.card(app, 0))
		ReviewCardScreen.showEveryCard(app)
		return app
	}

	static func approve(_ app: XCUIApplication) {
		tap(app, "chat.preview.add")
	}

	static func tap(_ app: XCUIApplication, _ identifier: String) {
		let control = ReviewCardScreen.bar(app).buttons.matching(identifier: identifier).firstMatch
		TutorialHarness.wait(control, until: .enabled)
		TutorialHarness.scroll(app, to: control)
		control.tap()
	}

	static func expect(
		_ app: XCUIApplication, _ identifier: String, reading sentences: [String],
		file: StaticString = #filePath, line: UInt = #line
	) {
		let element = TutorialHarness.named(app, identifier)
		ReviewCardScreen.reveal(app, element, file: file, line: line)
		TutorialHarness.wait(
			until: { element.exists && sentences.allSatisfy(element.label.contains) },
			message: "\(identifier) did not read \(sentences): \(element.label)", file: file,
			line: line)
	}

	static func expectFinished(
		_ app: XCUIApplication, _ lines: [String], file: StaticString = #filePath,
		line: UInt = #line
	) {
		let box = TutorialHarness.named(app, "chat.preview.finished")
		ReviewCardScreen.reveal(app, box, direction: .down, file: file, line: line)
		let title = box.staticTexts.matching(identifier: "chat.preview.finished.title").firstMatch
		XCTAssertEqual(title.label, "Already completed", file: file, line: line)
		let shown = box.staticTexts.matching(identifier: "chat.preview.finished.line")
			.allElementsBoundByIndex.map(\.label)
		XCTAssertEqual(shown, lines, file: file, line: line)
	}

	static func expectStatus(
		_ app: XCUIApplication, card index: Int, _ status: String, file: StaticString = #filePath,
		line: UInt = #line
	) {
		let card = ReviewCardScreen.card(app, index)
		ReviewCardScreen.reveal(app, card, direction: .down, file: file, line: line)
		XCTAssertEqual(
			card.staticTexts.matching(identifier: "chat.preview.card.status").firstMatch.label,
			status, file: file, line: line)
	}

	static func expectNote(
		_ app: XCUIApplication, _ lines: [String], closing: String,
		file: StaticString = #filePath, line: UInt = #line
	) {
		let note = TutorialHarness.named(app, "chat.note")
		TutorialHarness.wait(note, within: .turn)
		ReviewCardScreen.reveal(app, note, file: file, line: line)
		for expected in lines {
			XCTAssertTrue(
				note.label.contains(expected), "\(expected) | \(note.label)", file: file, line: line
			)
		}
		TutorialHarness.waitForIdentifier(app, "chat.note.closing", reading: closing)
		XCTAssertFalse(
			TutorialHarness.named(app, "chat.preview.title").exists, file: file, line: line)
		ReviewCardScreen.assertButtons(app, .none, file: file, line: line)
	}
}

@MainActor
final class ReviewPartialProof: XCTestCase {
	func testARefusedEditKeepsTheFinishedApartAndOffersTryAgain() {
		let app = ReviewStates.arrive(at: .partial)
		ReviewStates.approve(app)
		ReviewStates.expect(app, "chat.review.notice", reading: [ReviewStates.partial])
		ReviewCardScreen.assertButtons(app, .tryAgainOrCancel)
		XCTAssertEqual(
			app.staticTexts.matching(identifier: "chat.review.notice").count, 1,
			"the refused change was told twice")
		ReviewStates.expectFinished(
			app,
			[
				"\(ReviewStates.firstAdd): change saved.",
				"\(ReviewStates.secondAdd): change saved.",
			])
		ReviewStates.expectStatus(app, card: 2, "Not saved")
		TutorialHarness.attach(self, name: "u8-3-review-partial", app: app)
	}
}

@MainActor
final class ReviewRetriedProof: XCTestCase {
	func testTryAgainFinishesTheRestAndTheGoneDeleteReadsNoLongerOnTheCalendar() {
		let app = ReviewStates.arrive(at: .partial)
		ReviewStates.approve(app)
		ReviewCardScreen.assertButtons(app, .tryAgainOrCancel)
		ReviewStates.tap(app, "chat.preview.tryAgain")
		ReviewStates.expectNote(
			app,
			[
				"\(ReviewStates.firstAdd): change saved.",
				"\(ReviewStates.secondAdd): change saved.",
				"\(ReviewStates.edit): change saved.",
				"\(ReviewStates.delete): no longer on the calendar.",
			], closing: ReviewStates.completed)
		TutorialHarness.attach(self, name: "u8-3-review-retried", app: app)
	}
}

@MainActor
final class ReviewCanceledProof: XCTestCase {
	func testCancelAfterARefusalKeepsTheSavedLinesAndClosesTheRest() {
		let app = ReviewStates.arrive(at: .partial)
		ReviewStates.approve(app)
		ReviewCardScreen.assertButtons(app, .tryAgainOrCancel)
		ReviewStates.tap(app, "chat.preview.cancel")
		ReviewStates.expectNote(
			app,
			[
				"\(ReviewStates.firstAdd): change saved.",
				"\(ReviewStates.secondAdd): change saved.",
				"\(ReviewStates.edit): change not made.",
				"\(ReviewStates.delete): change not made.",
			], closing: ReviewStates.canceled)
		TutorialHarness.attach(self, name: "u8-3-review-canceled", app: app)
	}
}

@MainActor
final class ReviewSendingProof: XCTestCase {
	func testASendingReviewSaysSoWithTheFinishedApartAndNoControl() {
		let app = ReviewStates.arrive(at: .sending)
		ReviewStates.approve(app)
		ReviewStates.expect(app, "chat.review.notice", reading: [ReviewStates.sending])
		ReviewCardScreen.assertButtons(app, .none)
		ReviewStates.expectFinished(app, ["\(ReviewStates.firstAdd): change saved."])
		ReviewStates.expectStatus(app, card: 1, "Sending…")
		TutorialHarness.attach(self, name: "u8-3-review-sending", app: app)
	}
}

@MainActor
final class ReviewUnconfirmedProof: XCTestCase {
	func testALostAnswerMayHaveBeenSavedUntilCheckAgainSeesItOnTheCalendar() {
		let app = ReviewStates.arrive(at: .unconfirmed)
		ReviewStates.approve(app)
		ReviewStates.expect(app, "chat.review.notice", reading: [ReviewStates.unconfirmed])
		ReviewCardScreen.assertButtons(app, .checkAgainOrCancel)
		XCTAssertEqual(
			app.staticTexts.matching(identifier: "chat.review.notice").count, 1,
			"the unconfirmed change was told twice")
		ReviewStates.expectStatus(app, card: 0, "May have been saved")
		XCTAssertFalse(TutorialHarness.named(app, "chat.preview.finished").exists)
		TutorialHarness.attach(self, name: "u8-3-review-unconfirmed", app: app)
		ReviewStates.tap(app, "chat.preview.checkAgain")
		ReviewStates.expect(app, "chat.review.notice", reading: [ReviewStates.stopped])
		ReviewCardScreen.assertButtons(app, .tryAgainOrCancel)
		ReviewStates.expectFinished(
			app, ["\(ReviewStates.firstAdd): change seen on the calendar."])
		TutorialHarness.attach(self, name: "u8-3-review-unconfirmed-seen", app: app)
	}
}

@MainActor
final class ReviewCompletedProof: XCTestCase {
	func testACompletedReviewTellsSeenOnTheCalendarApartFromSaved() {
		let app = ReviewStates.arrive(at: .unconfirmed)
		ReviewStates.approve(app)
		ReviewCardScreen.assertButtons(app, .checkAgainOrCancel)
		ReviewStates.tap(app, "chat.preview.checkAgain")
		ReviewCardScreen.assertButtons(app, .tryAgainOrCancel)
		ReviewStates.tap(app, "chat.preview.tryAgain")
		ReviewStates.expectNote(
			app,
			[
				"\(ReviewStates.firstAdd): change seen on the calendar.",
				"\(ReviewStates.secondAdd): change saved.",
				"\(ReviewStates.edit): change saved.",
				"\(ReviewStates.delete): change saved.",
			], closing: ReviewStates.completed)
		TutorialHarness.attach(self, name: "u8-3-review-completed", app: app)
	}
}

@MainActor
final class ReviewRefreshedProof: XCTestCase {
	func testAWorkoutChangedOnTheCalendarNamesTheChangeAndAsksAgain() {
		let app = ReviewStates.arrive(at: .refreshed)
		ReviewStates.approve(app)
		ReviewStates.expect(
			app, "chat.review.notice",
			reading: [ReviewStates.refreshed, ReviewStates.refreshedDuration])
		XCTAssertEqual(app.staticTexts.matching(identifier: "chat.review.notice").count, 1)
		ReviewCardScreen.showEveryCard(app)
		let buttons = ReviewCardScreen.bar(app).buttons.allElementsBoundByIndex.map {
			($0.identifier, $0.label)
		}
		XCTAssertEqual(buttons.map(\.0), ["chat.preview.cancel", "chat.preview.add"])
		XCTAssertEqual(buttons.map(\.1), ["Cancel", "Apply changes"])
		TutorialHarness.attach(self, name: "u8-3-review-refreshed", app: app)
	}
}

@MainActor
final class ReviewBlockedProof: XCTestCase {
	func testAMissingWorkoutBlocksWithItsReasonBeforeAndAfterARelaunch() {
		let app = ReviewStates.arrive(at: .blocked)
		ReviewStates.approve(app)
		ReviewStates.expect(app, "chat.review.notice", reading: [ReviewStates.missing])
		ReviewCardScreen.assertButtons(app, .cancelOnly)
		XCTAssertEqual(app.staticTexts.matching(identifier: "chat.review.notice").count, 1)
		TutorialHarness.attach(self, name: "u8-3-review-blocked", app: app)
		TutorialHarness.relaunchKeepingStore(app)
		ReviewStates.expect(app, "chat.review.notice", reading: [ReviewStates.missing])
		let cancel = ReviewCardScreen.bar(app).buttons.matching(identifier: "chat.preview.cancel")
		ReviewCardScreen.reveal(app, cancel.firstMatch)
		ReviewCardScreen.assertButtons(app, .cancelOnly)
		TutorialHarness.attach(self, name: "u8-3-review-blocked-relaunched", app: app)
		ReviewStates.tap(app, "chat.preview.cancel")
		ReviewStates.expectNote(
			app,
			[
				"\(ReviewStates.firstAdd): change not made.",
				"\(ReviewStates.secondAdd): change not made.",
				"\(ReviewStates.edit): change not made.",
				"\(ReviewStates.delete): change not made.",
			], closing: ReviewStates.canceled)
		TutorialHarness.attach(self, name: "u8-3-review-canceled-first", app: app)
	}
}

@MainActor
final class ReviewStorageProof: XCTestCase {
	func testAStalledSendShowsOnlyTheStorageNoticeAndNoControl() {
		let app = ReviewStates.arrive(at: .storage)
		ReviewStates.approve(app)
		ReviewStates.expect(app, "chat.preview.notice", reading: [ReviewStates.storage])
		ReviewCardScreen.assertButtons(app, .none)
		XCTAssertFalse(TutorialHarness.named(app, "chat.review.notice").exists)
		TutorialHarness.attach(self, name: "u8-3-review-storage", app: app)
	}
}

@MainActor
final class ReviewNotPreparedProof: XCTestCase {
	func testARefusedPreparationSaysTheReviewCouldNotBePrepared() {
		let app = XCUIApplication()
		TutorialHarness.launch(app)
		TutorialHarness.completeOnboarding(app)
		TutorialHarness.exchange(app, "fixture:review-not-prepared")
		TutorialHarness.waitForIdentifier(
			app, "chat.turn.reviewNotice", reading: "The workout review could not be prepared.")
		XCTAssertFalse(TutorialHarness.named(app, "chat.preview.title").exists)
		ReviewCardScreen.assertButtons(app, .none)
		TutorialHarness.attach(self, name: "u8-3-review-not-prepared", app: app)
	}
}

@MainActor
final class ReviewStateLanguageProof: XCTestCase {
	func testGermanPreparedEarlierAndOutcomeNote() { expect(.de) }
	func testPortugalPortuguesePreparedEarlierAndOutcomeNote() { expect(.ptPT) }
	func testTraditionalChinesePreparedEarlierAndOutcomeNote() { expect(.zhHant) }

	private func expect(_ language: LanguageTag) {
		let run = MatrixRun.begin(self, language)
		TutorialHarness.exchange(run.app, TutorialHarness.workout)
		TutorialHarness.wait(run.named("chat.preview.add"), until: .enabled)
		TutorialHarness.startNewConversation(run.app, language: language)
		let earlier = run.named("chat.preview.preparedEarlier")
		ReviewCardScreen.reveal(run.app, earlier, direction: .down)
		run.expect("chat.preview.preparedEarlier", Catalog.workoutsPreparedEarlier)
		run.screen("review-prepared-earlier")
		TutorialHarness.wait(run.named("chat.preview.add"), until: .enabled, within: .turn)
		run.tap("chat.preview.add")
		let note = run.named("chat.note")
		TutorialHarness.wait(note, within: .turn)
		ReviewCardScreen.reveal(run.app, note)
		XCTAssertTrue(note.label.contains("Endurance with tempo"), note.label)
		run.expect("chat.note.closing", Catalog.workoutsCompleted)
		run.screen("review-outcome-note")
	}
}
