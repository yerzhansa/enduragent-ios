import EnduragentCoach
import XCTest

@MainActor
final class ReviewLongProof: XCTestCase {
	func testEightWorkoutsOverTenDaysShowEveryCardKeptWorkoutTheTotalsAndOneApproval() {
		ReviewLong.expectWhole(
			self, "fixture:review-eight", cards: 8,
			totals: "8 additions, 0 edits, 0 deletions · 320 min for added or edited workouts")
	}

	func testTwentyChangesShowEveryCardKeptWorkoutTheTotalsAndOneApproval() {
		ReviewLong.expectWhole(
			self, "fixture:review-twenty", cards: 20,
			totals: "20 additions, 0 edits, 0 deletions · 600 min for added or edited workouts")
	}

	func testFortyChangesShowEveryCardKeptWorkoutTheTotalsAndOneApproval() {
		ReviewLong.expectWhole(
			self, ReviewLongPresentationProof.forty, cards: 40,
			totals: "40 additions, 0 edits, 0 deletions · 1,200 min for added or edited workouts")
	}
}

@MainActor
enum ReviewLong {
	static let kept = [
		"Existing workouts kept", "6/17/1998", "Commute · 45 min", "6/18/1998",
		"Endurance · 60 min", "6/19/1998", "Recovery spin · 30 min",
	]

	static func prepared(_ directive: String, _ arguments: FixtureArguments) -> XCUIApplication {
		let app = XCUIApplication()
		TutorialHarness.launch(app, arguments: arguments)
		TutorialHarness.completeOnboarding(app)
		TutorialHarness.exchange(app, directive)
		TutorialHarness.wait(ReviewCardScreen.card(app, 0))
		return app
	}

	static func expectWhole(
		_ test: XCTestCase, _ directive: String, cards count: Int, totals: String
	) {
		let app = prepared(directive, FixtureArguments())
		let screen = "u8-4-review-long-\(count)"
		TutorialHarness.attach(test, name: "\(screen)-arriving", app: app)
		let reading = ReviewReadingOrder.read(app, until: "chat.preview.add")
		let heard = reading.transcript
		XCTAssertEqual(
			reading.parts,
			[.title] + (0..<count).map(ReviewReadingOrder.Part.card) + [.kept, .bar],
			"[\(count)] the review is not read whole and in order: \(heard)")
		XCTAssertTrue(reading.disorder.isEmpty, "[\(count)] \(reading.disorder)")
		for index in 0..<count {
			let lines = reading.lines(of: .card(index))
			XCTAssertEqual(
				lines.first?.identifier, "chat.preview.card.title", "[\(count)] \(heard)")
			XCTAssertTrue(
				lines.contains {
					$0.identifier == "chat.preview.card.heading"
						&& $0.label.hasPrefix("Add · \(index + 1) of \(count) · ")
				}, "[\(count)] card \(index) does not read its position: \(heard)")
		}
		XCTAssertEqual(reading.lines(of: .kept).map(\.label), kept, "[\(count)] \(heard)")
		TutorialHarness.waitForIdentifier(app, "chat.review.totals", reading: totals)
		let approvals = app.buttons.matching(identifier: "chat.preview.add")
		TutorialHarness.wait(approvals.firstMatch, until: .enabled)
		XCTAssertEqual(approvals.count, 1, "[\(count)] the review offers more than one approval")
		XCTAssertEqual(
			ReviewCardScreen.bar(app).buttons.allElementsBoundByIndex.map(\.label),
			["Cancel", "Add to calendar"])
		TutorialHarness.attach(test, name: "\(screen)-end", app: app)
	}

	static func audit(_ app: XCUIApplication, _ screen: String) {
		do {
			try app.performAccessibilityAudit(for: [.textClipped, .hitRegion]) { issue in
				guard let element = issue.element, element.exists else { return true }
				return !reviewed(element.identifier)
			}
		} catch {
			XCTFail("\(screen): the accessibility audit did not run: \(error)")
		}
	}

	static func reviewed(_ identifier: String) -> Bool {
		identifier.hasPrefix("chat.preview.") || identifier.hasPrefix("chat.review.")
			|| identifier == "chat.note"
	}
}
