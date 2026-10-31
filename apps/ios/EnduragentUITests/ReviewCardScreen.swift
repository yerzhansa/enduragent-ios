import XCTest

enum ReviewCardScreen {
	enum Layout: String {
		case approveOrCancel, tryAgainOrCancel, checkAgainOrCancel, cancelOnly, none

		var buttons: [String: String] {
			switch self {
			case .approveOrCancel:
				["chat.preview.cancel": "Cancel", "chat.preview.add": "Add to calendar"]
			case .tryAgainOrCancel:
				["chat.preview.tryAgain": "Try again", "chat.preview.cancel": "Cancel"]
			case .checkAgainOrCancel:
				["chat.preview.checkAgain": "Check again", "chat.preview.cancel": "Cancel"]
			case .cancelOnly: ["chat.preview.cancel": "Cancel"]
			case .none: [:]
			}
		}
	}

	static func assertButtons(
		_ container: XCUIElement, _ layout: Layout, enabled: Bool = true,
		file: StaticString = #filePath, line: UInt = #line
	) {
		let controls = container.buttons.matching(
			NSPredicate(format: "identifier BEGINSWITH %@", "chat.preview."))
		let expected = layout.buttons
		TutorialHarness.wait(
			until: {
				controls.count == expected.count
					&& controls.allElementsBoundByIndex.allSatisfy {
						expected[$0.identifier] == $0.label && $0.isEnabled == enabled
					}
			}, message: "The review did not reach its \(layout.rawValue) buttons", file: file,
			line: line)
		XCTAssertEqual(
			Set(controls.allElementsBoundByIndex.map { $0.identifier }), Set(expected.keys),
			file: file, line: line)
		XCTAssertFalse(
			container.buttons.matching(identifier: "chat.turn.tryAgain").firstMatch.exists,
			file: file, line: line)
	}

	static func bar(_ app: XCUIApplication) -> XCUIElement {
		TutorialHarness.named(app, "chat.review.bar")
	}

	static func card(_ app: XCUIApplication, _ index: Int) -> XCUIElement {
		TutorialHarness.named(app, "chat.transcript").descendants(matching: .any)
			.matching(identifier: "chat.preview.card.\(index)").firstMatch
	}

	static func reveal(
		_ app: XCUIApplication, _ element: XCUIElement,
		direction: TutorialHarness.ScrollDirection = .up, beforeEachStep: @escaping () -> Void = {},
		file: StaticString = #filePath, line: UInt = #line
	) {
		TutorialHarness.wait(
			until: {
				if element.exists { return true }
				beforeEachStep()
				step(app, direction)
				return element.exists
			}, within: .bulk, message: "\(element) never appeared in the transcript", file: file,
			line: line)
	}

	static func showEveryCard(_ app: XCUIApplication) {
		let approve = bar(app).buttons.matching(identifier: "chat.preview.add").firstMatch
		reveal(app, approve)
		TutorialHarness.wait(approve, until: .enabled)
		reveal(app, TutorialHarness.named(app, "chat.preview.title"), direction: .down)
	}

	private static func step(_ app: XCUIApplication, _ direction: TutorialHarness.ScrollDirection) {
		let band = TutorialHarness.transcriptBand(app)
		let reach = band.height * 0.3
		let upper = CGPoint(x: band.midX, y: band.midY - reach)
		let lower = CGPoint(x: band.midX, y: band.midY + reach)
		switch direction {
		case .up: TutorialHarness.drag(app, from: lower, to: upper, pace: .steady)
		case .down: TutorialHarness.drag(app, from: upper, to: lower, pace: .steady)
		}
	}
}
