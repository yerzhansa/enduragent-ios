import XCTest

@MainActor
final class ReviewCardsAddProof: XCTestCase {
	func testEachAddCardShowsItsPositionDateDurationStepsAndEstimatedLoad() {
		let app = ReviewCardContent.prepared(ReviewCardContent.mixed)
		let ride = ReviewCardContent.card(app, 0)
		ReviewCardContent.expect(ride, title: "Endurance 50")
		ReviewCardContent.expect(ride, heading: "Add · 1 of 4 · 6/16/1998 · 50 min")
		ReviewCardContent.expect(
			ride,
			steps: ["Warmup", "- 10m 55%", "Main set", "- 30m 65-75%", "Cooldown", "- 10m 50%"])
		ReviewCardContent.expect(ride, load: "Estimated training load: 42")
		ReviewCardContent.expect(ride, changes: [])
		let strength = ReviewCardContent.card(app, 1)
		ReviewCardContent.expect(strength, title: "Core strength")
		ReviewCardContent.expect(strength, heading: "Add · 2 of 4 · 6/17/1998 · 30 min")
		ReviewCardContent.expect(
			strength,
			steps: ["Moderate", "3 rounds: plank 45s, side plank 30s, glute bridge 12"])
		ReviewCardContent.expect(strength, load: "Estimated training load: 18")
		TutorialHarness.attach(self, name: "u8-1-review-cards-add", app: app)
		TutorialHarness.bringIntoTranscript(app, ReviewCardContent.approve(app))
		TutorialHarness.attach(self, name: "u8-1-review-cards-add-scrolled", app: app)
	}
}

@MainActor
final class ReviewCardsEditProof: XCTestCase {
	func testTheEditShowsBothDurationsAndARenameKeepsItsSteps() {
		let app = ReviewCardContent.prepared(ReviewCardContent.mixed)
		let edit = ReviewCardContent.card(app, 2)
		ReviewCardContent.expect(edit, title: "Endurance")
		ReviewCardContent.expect(edit, heading: "Edit · 3 of 4 · 6/18/1998 · 75 min")
		ReviewCardContent.expect(
			edit, changes: ["Duration: 60 min → 75 min", "The workout steps change."])
		let steps = ReviewCardContent.line(edit, "steps")
		TutorialHarness.wait(steps)
		let readable = steps.label
		XCTAssertTrue(readable.contains("Main set 3x"), readable)
		XCTAssertFalse(readable.contains("Steady ride"), readable)
		TutorialHarness.bringIntoTranscript(app, edit)
		TutorialHarness.attach(self, name: "u8-1-review-cards-edit", app: app)

		TutorialHarness.exchange(app, ReviewCardContent.rename)

		let renamed = ReviewCardContent.card(app, 2)
		ReviewCardContent.expect(renamed, title: "Threshold 3x10")
		ReviewCardContent.expect(
			renamed,
			changes: [
				"Name: Endurance → Threshold 3x10", "Duration: 60 min → 75 min",
				"The workout steps change.",
			])
		XCTAssertEqual(ReviewCardContent.line(renamed, "steps").label, readable)
		TutorialHarness.bringIntoTranscript(app, renamed)
		TutorialHarness.attach(self, name: "u8-1-review-cards-edit-renamed", app: app)
	}
}

@MainActor
final class ReviewCardsDeleteProof: XCTestCase {
	func testADeleteCardSaysItWillBeRemovedAndTheReviewOffersNoAdd() {
		let app = ReviewCardContent.prepared(ReviewCardContent.deleteOnly)
		let delete = ReviewCardContent.card(app, 0)
		ReviewCardContent.expect(delete, title: "Recovery spin")
		ReviewCardContent.expect(delete, heading: "Delete · 1 of 1 · 6/19/1998 · 30 min")
		ReviewCardContent.expect(
			delete, changes: ["This workout will be removed from the calendar."])
		XCTAssertFalse(ReviewCardContent.line(delete, "load").exists)
		let review = ReviewCardScreen.card(app)
		let apply = ReviewCardContent.approve(app)
		TutorialHarness.wait(apply, until: .enabled)
		XCTAssertEqual(apply.label, "Apply changes")
		XCTAssertEqual(
			review.buttons.matching(NSPredicate(format: "label == %@", "Add to calendar")).count, 0)
		TutorialHarness.attach(self, name: "u8-1-review-cards-delete", app: app)
	}
}

@MainActor
enum ReviewCardContent {
	static let mixed = "fixture:review-mixed"
	static let deleteOnly = "fixture:review-delete"
	static let rename = "fixture:review-rename"

	static func prepared(_ directive: String) -> XCUIApplication {
		let app = XCUIApplication()
		TutorialHarness.launch(app)
		TutorialHarness.completeOnboarding(app)
		TutorialHarness.exchange(app, directive)
		TutorialHarness.wait(approve(app), until: .enabled)
		return app
	}

	static func approve(_ app: XCUIApplication) -> XCUIElement {
		ReviewCardScreen.card(app).buttons.matching(identifier: "chat.preview.add").firstMatch
	}

	static func card(_ app: XCUIApplication, _ index: Int) -> XCUIElement {
		let card = ReviewCardScreen.card(app).descendants(matching: .any)
			.matching(identifier: "chat.preview.card.\(index)").firstMatch
		TutorialHarness.wait(card)
		return card
	}

	static func line(_ card: XCUIElement, _ part: String) -> XCUIElement {
		card.staticTexts.matching(identifier: "chat.preview.card.\(part)").firstMatch
	}

	static func expect(
		_ card: XCUIElement, title: String, file: StaticString = #filePath, line: UInt = #line
	) {
		expect(card, "title", reads: title, file: file, line: line)
	}

	static func expect(
		_ card: XCUIElement, heading: String, file: StaticString = #filePath, line: UInt = #line
	) {
		expect(card, "heading", reads: heading, file: file, line: line)
	}

	static func expect(
		_ card: XCUIElement, load: String, file: StaticString = #filePath, line: UInt = #line
	) {
		expect(card, "load", reads: load, file: file, line: line)
	}

	static func expect(
		_ card: XCUIElement, steps: [String], file: StaticString = #filePath, line: UInt = #line
	) {
		let shown = self.line(card, "steps")
		TutorialHarness.wait(shown, file: file, line: line)
		let lines = shown.label.split(separator: "\n").map(String.init)
		XCTAssertEqual(lines, steps, file: file, line: line)
	}

	static func expect(
		_ card: XCUIElement, changes: [String], file: StaticString = #filePath, line: UInt = #line
	) {
		let shown = card.staticTexts.matching(identifier: "chat.preview.card.change")
		TutorialHarness.wait(
			until: { shown.allElementsBoundByIndex.map(\.label) == changes },
			message: "\(card) did not list the changes \(changes)", file: file, line: line)
	}

	private static func expect(
		_ card: XCUIElement, _ part: String, reads label: String, file: StaticString,
		line: UInt
	) {
		let shown = self.line(card, part)
		TutorialHarness.wait(
			until: { shown.exists && shown.label == label },
			message: "\(card) did not show its \(part) \"\(label)\"", file: file, line: line)
	}
}
