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

	static func card(_ app: XCUIApplication) -> XCUIElement {
		TutorialHarness.named(app, "chat.transcript").cells.containing(
			NSPredicate(format: "identifier BEGINSWITH %@", "chat.preview.")
		).firstMatch
	}
}
