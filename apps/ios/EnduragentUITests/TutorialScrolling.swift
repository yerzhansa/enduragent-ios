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
		let top = app.navigationBars.firstMatch.frame.maxY
		let transcript = named(app, "chat.transcript")
		let bottom = ["chat.review.bar", "chat.planSave.bar"].reduce(
			named(app, "chat.composer.container").frame.minY
		) { lowest, identifier in
			let bar = named(app, identifier)
			let closingItsCard = transcript.descendants(matching: .any)
				.matching(identifier: identifier).firstMatch
			return bar.exists && !closingItsCard.exists ? min(lowest, bar.frame.minY) : lowest
		}
		return CGRect(x: app.frame.minX, y: top, width: app.frame.width, height: bottom - top)
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
				let floor = band.minY + band.height * topShare
				if frame.minY >= band.minY && frame.maxY <= floor { return true }
				let above = frame.minY < band.minY
				let remaining = above ? band.minY - frame.minY : frame.maxY - floor
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
