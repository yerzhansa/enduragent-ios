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

	enum DragPace {
		case fling, steady
	}

	static func transcriptBand(_ app: XCUIApplication) -> CGRect {
		MainActor.assumeIsolated {
			do {
				return transcriptBand(on: try app.snapshot())
			} catch {
				XCTFail("The screen could not be read for the transcript band: \(error)")
				return .zero
			}
		}
	}

	@MainActor
	private static func transcriptBand(on screen: any XCUIElementSnapshot) -> CGRect {
		guard let navigation = first(in: screen, where: { $0.elementType == .navigationBar }),
			let composer = first(in: screen, where: { $0.identifier == "chat.composer.container" })
		else {
			XCTFail("The screen lacks the navigation bar or the composer that bound the transcript")
			return .zero
		}
		let top = navigation.frame.maxY
		let bottom = dockedBars(in: screen).reduce(composer.frame.minY) { min($0, $1.minY) }
		return CGRect(x: screen.frame.minX, y: top, width: screen.frame.width, height: bottom - top)
	}

	@MainActor
	private static func dockedBars(in element: any XCUIElementSnapshot) -> [CGRect] {
		guard element.identifier != "chat.transcript" else { return [] }
		let bar = ["chat.review.bar", "chat.planSave.bar"].contains(element.identifier)
		return (bar ? [element.frame] : []) + element.children.flatMap { dockedBars(in: $0) }
	}

	@MainActor
	private static func first(
		in element: any XCUIElementSnapshot, where matches: (any XCUIElementSnapshot) -> Bool
	) -> (any XCUIElementSnapshot)? {
		if matches(element) { return element }
		for child in element.children {
			if let found = first(in: child, where: matches) { return found }
		}
		return nil
	}

	static func drag(
		_ app: XCUIApplication, from start: CGPoint, to end: CGPoint, pace: DragPace
	) {
		let screen = app.coordinate(withNormalizedOffset: .zero)
		let press = screen.withOffset(CGVector(dx: start.x, dy: start.y))
		let release = screen.withOffset(CGVector(dx: end.x, dy: end.y))
		switch pace {
		case .fling:
			press.press(forDuration: 0.05, thenDragTo: release)
		case .steady:
			press.press(
				forDuration: 0.05, thenDragTo: release, withVelocity: .slow,
				thenHoldForDuration: 0.2)
		}
	}

	static func bringIntoTranscript(
		_ app: XCUIApplication, _ element: XCUIElement, topShare: CGFloat = 1,
		afterStride: @escaping () -> Void = {}
	) {
		wait(element)
		wait(
			until: {
				let band = transcriptBand(app)
				let frame = element.frame
				let share = band.height * topShare
				let lowestTop =
					band.minY + (frame.height > share ? share / 2 : share - frame.height)
				if frame.minY >= band.minY && frame.minY <= lowestTop { return true }
				let above = frame.minY < band.minY
				let remaining = above ? band.minY - frame.minY : frame.minY - lowestTop
				let far = remaining > band.height
				let reach = band.height * (far ? 0.35 : 0.1)
				let upper = CGPoint(x: band.midX, y: band.midY - reach)
				let lower = CGPoint(x: band.midX, y: band.midY + reach)
				drag(app, from: above ? upper : lower, to: above ? lower : upper, pace: .steady)
				if far { afterStride() }
				return false
			}, within: .bulk, message: "\(element) did not scroll into the visible transcript")
	}

	static func debugRow(
		_ app: XCUIApplication, _ identifier: String, direction: ScrollDirection = .up
	) -> XCUIElement {
		let row = named(app, identifier)
		scroll(app, to: row, direction: direction)
		return row
	}
}
