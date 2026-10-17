import XCTest

@MainActor
final class ReviewTotalsProof: XCTestCase {
	func testTheMixedReviewTotalsItsChangesAndKeepsTheCommuteUnderItsDate() {
		let app = ReviewCardContent.prepared(ReviewCardContent.mixed)
		TutorialHarness.waitForIdentifier(
			app, "chat.review.totals",
			reading: "2 additions, 1 edit, 1 deletion · 155 min for added or edited workouts")
		TutorialHarness.attach(self, name: "u8-2-review-totals", app: app)
		let kept = TutorialHarness.named(app, "chat.preview.kept")
		ReviewCardScreen.reveal(app, kept)
		TutorialHarness.bringIntoTranscript(app, kept)
		let lines = kept.staticTexts.allElementsBoundByIndex.map { ($0.identifier, $0.label) }
		XCTAssertEqual(
			lines.map(\.0),
			["chat.preview.kept.title", "chat.preview.kept.day", "chat.preview.kept.workout"])
		XCTAssertEqual(
			lines.map(\.1), ["Existing workouts kept", "6/17/1998", "Commute · 45 min"])
		let day = kept.staticTexts.matching(identifier: "chat.preview.kept.day").firstMatch
		let workout = kept.staticTexts.matching(identifier: "chat.preview.kept.workout")
			.firstMatch
		XCTAssertLessThanOrEqual(day.frame.maxY, workout.frame.minY + 1)
		TutorialHarness.attach(self, name: "u8-2-review-totals-kept", app: app)
	}
}

@MainActor
final class ReviewApprovalBarProof: XCTestCase {
	func testAnAddOnlyReviewAsksToAddIt() {
		expect(
			TutorialHarness.workout, asks: "Add this workout to your calendar?",
			approving: "Add to calendar", screen: "add")
	}

	func testAnEditOnlyReviewAsksToUpdateIt() {
		expect(
			"fixture:review-edit", asks: "Update this workout on your calendar?",
			approving: "Update calendar", screen: "edit")
	}

	func testADeleteOnlyReviewAsksToRemoveIt() {
		expect(
			ReviewCardContent.deleteOnly, asks: "Remove this workout from your calendar?",
			approving: "Remove from calendar", screen: "delete")
	}

	func testAMixedReviewAsksToApplyEveryChange() {
		expect(
			ReviewCardContent.mixed, asks: "Apply all reviewed changes?",
			approving: "Apply changes", screen: "mixed")
	}

	private func expect(
		_ directive: String, asks question: String, approving title: String, screen: String
	) {
		let app = ReviewCardContent.prepared(directive)
		let bar = ReviewCardScreen.bar(app)
		TutorialHarness.waitForIdentifier(app, "chat.review.question", reading: question)
		let buttons = bar.buttons.allElementsBoundByIndex.map { ($0.identifier, $0.label) }
		XCTAssertEqual(buttons.map(\.0), ["chat.preview.cancel", "chat.preview.add"])
		XCTAssertEqual(buttons.map(\.1), ["Cancel", title])
		XCTAssertFalse(TutorialHarness.named(app, "chat.review.status").exists)
		TutorialHarness.attach(self, name: "u8-2-review-approval-bar-\(screen)", app: app)
	}
}

@MainActor
final class ReviewLongPresentationProof: XCTestCase {
	static let forty = "fixture:review-forty"
	static let unseen = "Scroll through every card to continue."

	func testNoApproveExistsBeforeTheLastOfFortyCardsHasAppeared() {
		let app = arrived(FixtureArguments())
		TutorialHarness.attach(self, name: "u8-2-review-long-arriving", app: app)
		walkToTheLastCard(app)
		TutorialHarness.wait(approve(app), until: .enabled)
		XCTAssertFalse(TutorialHarness.named(app, "chat.review.status").exists)
		TutorialHarness.attach(self, name: "u8-2-review-long-armed", app: app)
	}

	func testALastCardThatFailsLeavesNoApproveUntilTheReviewIsShownAgainWhole() {
		let app = arrived(FixtureArguments(presentationFault: .failLastCardOnce))
		walkToTheLastCard(app)
		TutorialHarness.waitForIdentifier(
			app, "chat.review.status",
			reading: "Card 40 of 40 could not be shown. Nothing was changed.")
		let showAgain = TutorialHarness.named(app, "chat.review.showAgain")
		TutorialHarness.wait(showAgain, until: .hittable)
		XCTAssertFalse(approve(app).exists, "a review whose last card failed offered Approve")
		TutorialHarness.attach(self, name: "u8-2-review-card-failed", app: app)

		showAgain.tap()
		TutorialHarness.wait(ReviewCardScreen.card(app, 0))
		TutorialHarness.waitForIdentifier(app, "chat.review.status", reading: Self.unseen)
		XCTAssertFalse(showAgain.exists)
		walkToTheLastCard(app)
		TutorialHarness.wait(approve(app), until: .enabled)
		TutorialHarness.attach(self, name: "u8-2-review-card-failed-shown-again", app: app)
	}

	private func arrived(_ arguments: FixtureArguments) -> XCUIApplication {
		let app = XCUIApplication()
		TutorialHarness.launch(app, arguments: arguments)
		TutorialHarness.completeOnboarding(app)
		TutorialHarness.exchange(app, Self.forty)
		TutorialHarness.wait(ReviewCardScreen.card(app, 0))
		TutorialHarness.waitForIdentifier(app, "chat.review.status", reading: Self.unseen)
		XCTAssertFalse(approve(app).exists, "Approve appeared before any card was scrolled to")
		return app
	}

	private func walkToTheLastCard(_ app: XCUIApplication) {
		let approve = approve(app)
		ReviewCardScreen.reveal(app, ReviewCardScreen.card(app, 39)) {
			XCTAssertFalse(approve.exists, "Approve appeared before the last card did")
		}
	}

	private func approve(_ app: XCUIApplication) -> XCUIElement {
		ReviewCardScreen.bar(app).buttons.matching(identifier: "chat.preview.add").firstMatch
	}
}
