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
final class ReviewLargestTextFortyProof: XCTestCase {
	func testApproveAndCancelAreHittableOnTheFortyChangeReviewAtTheLargestTextSize() {
		let arguments = FixtureArguments()
		let app = ReviewLong.prepared(ReviewLongPresentationProof.forty, arguments)
		ReviewAccessibility.reopenAtLargestText(app, arguments)
		TutorialHarness.wait(ReviewCardScreen.card(app, 0), within: .turn)
		let last = ReviewCardScreen.card(app, 39)
		ReviewCardScreen.reveal(app, last)
		TutorialHarness.bringIntoTranscript(app, last)
		let card = ReviewCardReading(run: MatrixRun(test: self, app: app, language: .en))
		TutorialHarness.wait(TutorialHarness.named(app, "chat.preview.add"), until: .enabled)
		XCTAssertTrue(
			TutorialHarness.named(app, "chat.transcript").descendants(matching: .any)
				.matching(identifier: ReviewCardReading.bar).firstMatch.exists,
			"at the largest text size the bar does not close the review in the transcript")
		for control in [ReviewCardReading.Control.add, .cancel] {
			let button = card.reach(control)
			let band = TutorialHarness.transcriptBand(app)
			XCTAssertTrue(button.isHittable, "\(control.rawValue) is not hittable")
			XCTAssertTrue(button.isEnabled, "\(control.rawValue) is disabled")
			XCTAssertGreaterThanOrEqual(
				button.frame.height, ReviewCardReading.minimumTarget,
				"\(control.rawValue) \(button.frame) is not drawn at the largest text size")
			XCTAssertTrue(
				button.frame.minY >= band.minY && button.frame.maxY <= band.maxY,
				"\(control.rawValue) \(button.frame) is not whole in the transcript \(band)")
			ReviewLong.audit(app, "\(control.rawValue) at the largest text size")
			TutorialHarness.attach(
				self, name: "u8-4-review-largest-text-\(control == .add ? "approve" : "cancel")",
				app: app)
		}
		card.reach(.cancel).tap()
		TutorialHarness.wait(TutorialHarness.named(app, "chat.preview.cancel"), until: .absent)
		XCTAssertFalse(TutorialHarness.named(app, "chat.preview.add").exists)
		TutorialHarness.attach(self, name: "u8-4-review-largest-text-cancelled", app: app)
	}
}

@MainActor
final class ReviewVoiceOverProof: XCTestCase {
	func testAtTheDefaultSizeTheTitleEachCardInOrderTheNoticeThenTheControlsAreRead() {
		expectReadingOrder(textSize: nil, screen: "default")
	}

	func testAtTheLargestSizeTheTitleEachCardInOrderTheNoticeThenTheControlsAreRead() {
		expectReadingOrder(textSize: .accessibilityXXXL, screen: "largest")
	}

	private func expectReadingOrder(textSize: FixtureTextSize?, screen: String) {
		let app = ReviewLong.prepared("fixture:review-eight", FixtureArguments())
		app.terminate()
		XCTAssertEqual(app.state, .notRunning)
		var reopened = FixtureArguments(calendarReadFault: .failOnce)
		reopened.store = .keep
		reopened.textSize = textSize
		TutorialHarness.launch(app, arguments: reopened)
		TutorialHarness.wait(ReviewCardScreen.card(app, 0), within: .turn)
		let approve = TutorialHarness.named(app, "chat.preview.add")
		ReviewCardScreen.reveal(app, approve)
		TutorialHarness.wait(approve, until: .enabled, within: .turn)
		if textSize != nil {
			ReviewCardReading(run: MatrixRun(test: self, app: app, language: .en)).reach(.add)
		}
		TutorialHarness.wait(approve, until: .hittable)
		approve.tap()
		let notice = TutorialHarness.named(app, "chat.review.notice")
		TutorialHarness.wait(notice, within: .turn)
		TutorialHarness.wait(approve, until: .enabled, within: .turn)
		TutorialHarness.attach(self, name: "u8-4-review-voiceover-\(screen)-notice", app: app)

		let reading = ReviewReadingOrder.read(app, until: "chat.preview.add")
		let heard = reading.transcript
		XCTAssertEqual(
			reading.parts,
			[.title] + (0..<8).map(ReviewReadingOrder.Part.card) + [.kept, .notice, .bar],
			"[\(screen)] VoiceOver does not read the title, the cards in order, the notice, then the controls: \(heard)"
		)
		XCTAssertTrue(reading.disorder.isEmpty, "[\(screen)] \(reading.disorder)")
		XCTAssertEqual(
			reading.lines(of: .title).first?.identifier, "chat.preview.title",
			"[\(screen)] \(heard)")
		for index in 0..<8 {
			XCTAssertEqual(
				reading.lines(of: .card(index)).first?.identifier, "chat.preview.card.title",
				"[\(screen)] card \(index) does not start at its title: \(heard)")
		}
		XCTAssertEqual(
			reading.lines(of: .notice).map(\.identifier), ["chat.review.notice"],
			"[\(screen)] \(heard)")
		let bar = reading.lines(of: .bar)
		let firstControl = bar.firstIndex { $0.type == .button } ?? bar.endIndex
		XCTAssertEqual(bar.first?.identifier, "chat.review.totals", "[\(screen)] \(heard)")
		XCTAssertEqual(
			bar[firstControl...].map(\.identifier), ["chat.preview.cancel", "chat.preview.add"],
			"[\(screen)] the controls are not the last lines of the review: \(heard)")
		TutorialHarness.attach(self, name: "u8-4-review-voiceover-\(screen)-end", app: app)
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
