import XCTest

final class ReviewCardComposerProof: XCTestCase {
	@MainActor
	func testKeyboardKeepsReviewRowsAboveTheComposer() {
		let app = XCUIApplication()
		TutorialHarness.launch(app)
		TutorialHarness.completeOnboarding(app)
		TutorialHarness.exchange(app, TutorialHarness.workout)
		let add = TutorialHarness.named(app, "chat.preview.add")
		TutorialHarness.waitUntilEnabled(add)
		TutorialHarness.waitForLabel(app, "Workout review")
		TutorialHarness.waitForAbsence(app.keyboards.firstMatch)
		let input = TutorialHarness.named(app, "chat.composer")
		input.tap()
		input.typeText(TutorialHarness.draft)
		let keyboard = app.keyboards.firstMatch
		TutorialHarness.wait(keyboard)
		XCTAssertEqual(input.value as? String, TutorialHarness.draft)
		let composer = TutorialHarness.named(app, "chat.composer.container")
		TutorialHarness.wait(composer)
		let send = TutorialHarness.named(app, "chat.send")
		TutorialHarness.waitUntilHittable(send)
		TutorialHarness.waitUntilHittable(add)
		let composerFrame = composer.frame
		let transcript = TutorialHarness.named(app, "chat.transcript")
		XCTAssertTrue(
			transcript.cells.containing(.button, identifier: "chat.preview.add").firstMatch.exists)
		let viewport = transcript.frame.intersection(app.frame)
		let rows = transcript.cells.allElementsBoundByIndex
		let visibleFrames = rows.map { $0.frame.intersection(viewport) }.filter {
			!$0.isNull && !$0.isEmpty
		}
		XCTAssertFalse(visibleFrames.isEmpty, "no transcript rows were measured")
		for frame in visibleFrames {
			XCTAssertFalse(
				composerFrame.intersects(frame),
				"transcript row \(frame) overlaps composer \(composerFrame)")
		}
		XCTAssertLessThanOrEqual(add.frame.maxY, composerFrame.minY)
		XCTAssertLessThanOrEqual(composerFrame.maxY, keyboard.frame.minY)
		XCTAssertTrue(send.isHittable)
		TutorialHarness.attach(self, name: "review-card-composer-keyboard", app: app)
		TutorialHarness.assertZeroFixtureRequests(app)
	}
}
