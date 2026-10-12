import XCTest

extension TutorialHarness {
	enum ScrollDirection {
		case up, down
	}

	static func scroll(
		_ app: XCUIApplication, to element: XCUIElement, direction: ScrollDirection = .up
	) {
		let started = ProcessInfo.processInfo.systemUptime
		var layout: [String]?
		var stillSwipes = 0
		while !(element.exists && element.isHittable) {
			let elapsed = ProcessInfo.processInfo.systemUptime - started
			let stopped = stillSwipes >= 2 && elapsed >= Timeout.screen.rawValue
			guard !stopped, elapsed < Timeout.bulk.rawValue else {
				return XCTFail("Could not scroll to \(element)")
			}
			let before = layout ?? screenLayout(app)
			direction == .up ? app.swipeUp() : app.swipeDown()
			let after = screenLayout(app)
			stillSwipes = after == before ? stillSwipes + 1 : 0
			layout = after
		}
	}

	private static func screenLayout(_ app: XCUIApplication) -> [String] {
		func layout(of element: any XCUIElementSnapshot) -> [String] {
			["\(element.identifier)|\(element.label)|\(element.frame.integral)"]
				+ element.children.flatMap { layout(of: $0) }
		}
		return MainActor.assumeIsolated {
			do {
				return layout(of: try app.snapshot())
			} catch {
				XCTFail("The screen could not be read while scrolling: \(error)")
				return []
			}
		}
	}

	static func debugRow(
		_ app: XCUIApplication, _ identifier: String, direction: ScrollDirection = .up
	) -> XCUIElement {
		let row = named(app, identifier)
		scroll(app, to: row, direction: direction)
		return row
	}
}
