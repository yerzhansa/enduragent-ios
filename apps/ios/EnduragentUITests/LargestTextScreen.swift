import EnduragentCoach
import XCTest

@MainActor
enum LargestTextScreen {
	static let wholeRowShare: CGFloat = 0.7
	private static let pageLimit = 40
	private static let spokenTypes: Set<XCUIElement.ElementType> = [
		.staticText, .button, .link, .textField, .textView, .secureTextField,
	]

	struct Walk {
		var heard: [String] = []
		var disorder: [String] = []
		var inside: Set<String> = []
	}

	private struct Spoken {
		var identifier: String
		var frame: CGRect
	}

	static func begin(
		_ test: XCTestCase, _ language: LanguageTag,
		arguments: FixtureArguments = FixtureArguments(onboarded: true)
	) -> MatrixRun {
		let run = MatrixRun.begin(test, language, arguments: arguments)
		ReviewAccessibility.reopenAtLargestText(run.app, arguments)
		TutorialHarness.wait(run.named("chat.composer"), until: .hittable)
		return run
	}

	static func openSettings(_ app: XCUIApplication) {
		let settings = TutorialHarness.named(app, "chat.settings")
		TutorialHarness.wait(settings, until: .hittable)
		settings.tap()
		TutorialHarness.wait(TutorialHarness.named(app, "settings.accessMethod"))
	}

	static func open(_ app: XCUIApplication, row: String, showing content: String) {
		openSettings(app)
		let link = TutorialHarness.named(app, row)
		TutorialHarness.scroll(app, to: link)
		link.tap()
		TutorialHarness.wait(TutorialHarness.named(app, content))
	}

	static func window(_ app: XCUIApplication) -> CGRect {
		app.windows.firstMatch.frame
	}

	static func visible(_ app: XCUIApplication) -> CGRect {
		let window = window(app)
		let top = app.navigationBars.firstMatch.frame.maxY
		return CGRect(
			x: window.minX, y: top, width: window.width,
			height: SupportScreen.visibleBottom(app) - top)
	}

	static func reveal(
		_ app: XCUIApplication, _ element: XCUIElement, tappable: Bool,
		file: StaticString = #filePath, line: UInt = #line
	) {
		TutorialHarness.wait(
			until: {
				let region = visible(app)
				guard element.exists else {
					drag(app, in: region, forward: true)
					return false
				}
				let frame = element.frame
				if shown(frame, in: region) && (!tappable || element.isHittable) { return true }
				drag(app, in: region, forward: frame.minY > region.minY)
				return false
			}, within: .retry,
			message: "\(element) cannot be scrolled whole into the screen",
			file: file, line: line)
	}

	static func toTop(_ app: XCUIApplication) {
		var previous: [String] = []
		for _ in 0..<pageLimit {
			let layout = layout(app)
			if layout == previous { return }
			previous = layout
			drag(app, in: visible(app), forward: false)
		}
		XCTFail("The screen did not reach its top in \(pageLimit) pages")
	}

	static func walk(_ app: XCUIApplication, _ expected: [String]) -> Walk {
		var walk = Walk()
		var previous: [Spoken] = []
		for _ in 0..<pageLimit {
			let page = spoken(app, expected)
			let region = visible(app)
			for (earlier, later) in zip(page, page.dropFirst()) {
				let before = expected.firstIndex(of: earlier.identifier) ?? 0
				let after = expected.firstIndex(of: later.identifier) ?? 0
				if before >= after || !follows(earlier.frame, later.frame) {
					walk.disorder.append(
						"\(later.identifier) \(later.frame) is read after \(earlier.identifier) \(earlier.frame)"
					)
				}
			}
			for item in page {
				if !walk.heard.contains(item.identifier) { walk.heard.append(item.identifier) }
				if shown(item.frame, in: region) { walk.inside.insert(item.identifier) }
			}
			let settled = page.map(\.frame.integral) == previous.map(\.frame.integral)
			let complete = Set(walk.heard) == Set(expected) && walk.inside == Set(expected)
			if complete || settled {
				return walk
			}
			previous = page
			drag(app, in: region, forward: true)
		}
		return walk
	}

	static func expectOrder(
		_ app: XCUIApplication, _ expected: [String], screen: String,
		file: StaticString = #filePath, line: UInt = #line
	) {
		let walk = walk(app, expected)
		XCTAssertEqual(
			walk.heard, expected, "\(screen): VoiceOver does not read top to bottom",
			file: file, line: line)
		XCTAssertEqual(walk.disorder, [], "\(screen): reading order", file: file, line: line)
		XCTAssertEqual(
			walk.inside, Set(expected), "\(screen): a line never lay inside the window",
			file: file, line: line)
	}

	static func assertWhole(
		_ app: XCUIApplication, _ control: XCUIElement,
		file: StaticString = #filePath, line: UInt = #line
	) {
		let window = window(app)
		let frame = control.frame
		XCTAssertTrue(
			frame.minX >= window.minX - 1 && frame.maxX <= window.maxX + 1
				&& frame.minY >= window.minY - 1 && frame.maxY <= window.maxY + 1,
			"\(control) \(frame) leaves the window \(window)", file: file, line: line)
		XCTAssertGreaterThanOrEqual(
			frame.width, window.width * wholeRowShare, "\(control) is not full width",
			file: file, line: line)
		XCTAssertTrue(control.isHittable, "\(control) cannot be tapped", file: file, line: line)
	}

	static func shown(_ frame: CGRect, in region: CGRect) -> Bool {
		let across =
			frame.width > 0 && frame.minX >= region.minX - 1 && frame.maxX <= region.maxX + 1
		guard frame.height <= region.height else {
			return across && frame.minY >= region.minY - 1 && frame.minY < region.midY
		}
		return across && frame.minY >= region.minY - 1 && frame.maxY <= region.maxY + 1
	}

	static func follows(_ earlier: CGRect, _ later: CGRect) -> Bool {
		later.minY >= earlier.maxY - 2
			|| (later.minX >= earlier.maxX - 2 && later.maxY > earlier.minY)
	}

	static func drag(_ app: XCUIApplication, in region: CGRect, forward: Bool) {
		let reach = region.height * 0.2
		let x = region.minX + 10
		let upper = CGPoint(x: x, y: region.midY - reach)
		let lower = CGPoint(x: x, y: region.midY + reach)
		TutorialHarness.drag(
			app, from: forward ? lower : upper, to: forward ? upper : lower, pace: .steady)
	}

	private static func layout(_ app: XCUIApplication) -> [String] {
		do {
			return try app.snapshot().children.flatMap(describe)
		} catch {
			XCTFail("The screen could not be read: \(error)")
			return []
		}
	}

	private static func describe(_ node: any XCUIElementSnapshot) -> [String] {
		["\(node.identifier)|\(node.frame.integral)"] + node.children.flatMap(describe)
	}

	private static func spoken(_ app: XCUIApplication, _ expected: [String]) -> [Spoken] {
		var items: [Spoken] = []
		do {
			collect(try app.snapshot(), expected, into: &items)
		} catch {
			XCTFail("The screen could not be read: \(error)")
		}
		return items
	}

	private static func collect(
		_ node: any XCUIElementSnapshot, _ expected: [String], into items: inout [Spoken]
	) {
		if spokenTypes.contains(node.elementType), expected.contains(node.identifier) {
			if !items.contains(where: { $0.identifier == node.identifier }) {
				items.append(Spoken(identifier: node.identifier, frame: node.frame))
			}
			return
		}
		if node.elementType == .keyboard { return }
		for child in node.children { collect(child, expected, into: &items) }
	}
}
