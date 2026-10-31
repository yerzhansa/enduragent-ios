import EnduragentCoach
import XCTest

@MainActor
final class SettingsLargestTextSweepProof: XCTestCase {
	func testEveryControlReachable() {
		let app = SettingsSweep.launch(connected: true)
		let screens: [(screen: SettingsSweep.Screen, ready: String, count: Int)] = [
			(.settings, "settings.model", 11),
			(.accessMethod, "access.credits", 2),
			(.modelPicker, "model.choices", 2),
			(.credits, "credits.switchToOpenRouter", 1),
			(.training, "training.athlete", 3),
			(.languagePicker, "language.choice.automatic", 19),
		]
		var reached: [String] = []
		for entry in screens {
			entry.screen.open(app, showing: entry.ready)
			reached += SettingsSweep.sweep(self, app, entry.screen, expecting: entry.count)
			entry.screen.close(app)
		}
		XCTAssertEqual(reached, screens.map { SettingsSweep.title($0.screen) })
	}

	func testTrainingNotConnected() {
		let app = SettingsSweep.launch(connected: false)
		SettingsSweep.Screen.training.open(app, showing: "training.edit")
		let reached = SettingsSweep.sweep(self, app, .training, expecting: 1)
		let edit = TutorialHarness.named(app, "training.edit")
		LargestTextScreen.toTop(app)
		LargestTextScreen.reveal(app, edit, tappable: true)
		edit.tap()
		TutorialHarness.wait(TutorialHarness.named(app, "training.apiKey"))
		LargestTextScreen.toTop(app)
		let editing = SettingsSweep.sweep(self, app, .training, expecting: 3, name: "editing")
		XCTAssertEqual(
			reached + editing, Array(repeating: SettingsSweep.title(.training), count: 2))
		SettingsSweep.Screen.training.close(app)
	}
}

@MainActor
enum SettingsSweep {
	@MainActor
	enum Screen: String {
		case settings, accessMethod, modelPicker, credits, training, languagePicker

		var row: String? {
			switch self {
			case .settings: nil
			case .accessMethod: "settings.accessMethod"
			case .modelPicker: "settings.model"
			case .credits: "settings.credits"
			case .training: "settings.training"
			case .languagePicker: "settings.language"
			}
		}

		var titleKey: CatalogKey {
			switch self {
			case .settings: Catalog.settingsTitle
			case .accessMethod: Catalog.accessTitle
			case .modelPicker: Catalog.settingsCoachChooseModel
			case .credits: Catalog.creditsTitle
			case .training: Catalog.settingsTrainingTitle
			case .languagePicker: Catalog.languageChooseTitle
			}
		}

		var anchor: String? { self == .languagePicker ? "language.choice.automatic" : nil }

		func open(_ app: XCUIApplication, showing ready: String) {
			LargestTextScreen.openSettings(app)
			if let row {
				let link = TutorialHarness.named(app, row)
				TutorialHarness.scroll(app, to: link)
				link.tap()
			}
			TutorialHarness.wait(app.navigationBars[title(self)])
			TutorialHarness.wait(TutorialHarness.named(app, ready))
		}

		func close(_ app: XCUIApplication) {
			if self == .languagePicker {
				let close = TutorialHarness.named(app, "language.close")
				close.tap()
				TutorialHarness.wait(close, until: .absent)
			}
			TutorialHarness.returnToChat(app)
		}
	}

	private struct Control {
		var key: String
		var type: XCUIElement.ElementType
		var identifier: String
		var label: String
		var frame: CGRect
		var inBar: Bool
	}

	private static let pageLimit = 40
	private static let controlTypes: Set<XCUIElement.ElementType> = [
		.button, .link, .switch, .toggle, .textField, .secureTextField, .textView, .searchField,
	]

	static func title(_ screen: Screen) -> String {
		CatalogPhrasebook(tag: .en).say(screen.titleKey)
	}

	static func launch(connected: Bool) -> XCUIApplication {
		let app = XCUIApplication()
		let arguments = FixtureArguments(onboarded: true, accessMethod: .catalogOpenRouter)
		TutorialHarness.launch(app, arguments: arguments)
		TutorialHarness.agreeToProviderConsent(app)
		if connected {
			TutorialHarness.openCredentials(app)
			TutorialHarness.named(app, "training.edit").tap()
			TutorialHarness.type(app, "fixture", into: "training.apiKey")
			TutorialHarness.named(app, "training.save").tap()
			TutorialHarness.waitForIdentifier(app, "training.saved", reading: "Saved")
			TutorialHarness.returnToChat(app)
		}
		ReviewAccessibility.reopenAtLargestText(app, arguments)
		TutorialHarness.wait(TutorialHarness.named(app, "chat.composer"), until: .hittable)
		return app
	}

	static func sweep(
		_ test: XCTestCase, _ app: XCUIApplication, _ screen: Screen, expecting count: Int,
		name: String = "rest", file: StaticString = #filePath, line: UInt = #line
	) -> [String] {
		let title = title(screen)
		guard app.navigationBars[title].exists else {
			XCTFail("\(screen.rawValue) was not reached", file: file, line: line)
			return []
		}
		var seen: [Control] = []
		var proven: Set<String> = []
		var previous: [String] = []
		var still = 0
		var depth: Int?
		for _ in 0..<pageLimit {
			guard let page = page(app, title: title, anchor: screen.anchor, depth: &depth) else {
				break
			}
			for control in page.controls {
				if !seen.contains(where: { $0.key == control.key }) { seen.append(control) }
				let region = control.inBar ? LargestTextScreen.window(app) : page.content
				if !proven.contains(control.key),
					LargestTextScreen.shown(control.frame, in: region),
					control.frame.height <= region.height, hittable(app, control)
				{
					proven.insert(control.key)
				}
			}
			let layout = page.controls.map { "\($0.key)|\($0.frame.integral)" }
			still = layout == previous ? still + 1 : 0
			if still >= 2 { break }
			previous = layout
			LargestTextScreen.drag(app, in: page.content, forward: true)
		}
		let found = seen.map { "\($0.key) \($0.frame)" }.joined(separator: " | ")
		XCTAssertGreaterThan(count, 0, file: file, line: line)
		XCTAssertEqual(
			seen.count, count, "\(screen.rawValue) \(name): controls found: \(found)",
			file: file, line: line)
		XCTAssertEqual(
			seen.filter { !proven.contains($0.key) }.map(\.key), [],
			"\(screen.rawValue) \(name): these controls never lay whole inside the window and hittable",
			file: file, line: line)
		TutorialHarness.attach(test, name: "sweep-\(screen.rawValue)-\(name)-light", app: app)
		return [title]
	}

	private static func page(
		_ app: XCUIApplication, title: String, anchor: String?, depth: inout Int?
	) -> (controls: [Control], content: CGRect)? {
		let root: any XCUIElementSnapshot
		do {
			root = try app.snapshot()
		} catch {
			XCTFail("The screen could not be read: \(error)")
			return nil
		}
		guard
			let barPath = path(
				in: root, to: { $0.elementType == .navigationBar && $0.identifier == title })
		else {
			XCTFail("The \(title) navigation bar is not on screen")
			return nil
		}
		if depth == nil, let anchor {
			guard let anchorPath = path(in: root, to: { $0.identifier == anchor }) else {
				XCTFail("\(anchor) is not on screen")
				return nil
			}
			depth = zip(barPath, anchorPath).prefix { $0 == $1 }.count
		}
		let scope = node(at: Array(barPath.prefix(depth ?? 0)), in: root)
		let bar = node(at: barPath, in: root)
		let window = LargestTextScreen.window(app)
		let bottom = SupportScreen.visibleBottom(app)
		let content = CGRect(
			x: window.minX, y: bar.frame.maxY, width: window.width, height: bottom - bar.frame.maxY)
		var controls: [Control] = []
		collect(scope, inBar: false, into: &controls)
		return (controls, content)
	}

	private static func collect(
		_ node: any XCUIElementSnapshot, inBar: Bool, into controls: inout [Control]
	) {
		if node.elementType == .keyboard { return }
		let inBar = inBar || node.elementType == .navigationBar
		if controlTypes.contains(node.elementType) {
			guard !inBar || node.identifier.contains(".") else { return }
			let base = "\(name(of: node.elementType))|\(node.identifier)|\(node.label)"
			let ordinal = controls.filter { $0.key.hasPrefix(base + "#") }.count + 1
			controls.append(
				Control(
					key: "\(base)#\(ordinal)", type: node.elementType, identifier: node.identifier,
					label: node.label, frame: node.frame, inBar: inBar))
			return
		}
		for child in node.children { collect(child, inBar: inBar, into: &controls) }
	}

	private static func hittable(_ app: XCUIApplication, _ control: Control) -> Bool {
		let matches = app.descendants(matching: control.type).matching(
			NSPredicate(
				format: "identifier == %@ AND label == %@", control.identifier, control.label)
		).allElementsBoundByIndex
		return matches.contains { element in
			abs(element.frame.minY - control.frame.minY) <= 2
				&& abs(element.frame.minX - control.frame.minX) <= 2 && element.isHittable
		}
	}

	private static func path(
		in node: any XCUIElementSnapshot, to matches: (any XCUIElementSnapshot) -> Bool
	) -> [Int]? {
		if matches(node) { return [] }
		for (index, child) in node.children.enumerated() {
			if let rest = path(in: child, to: matches) { return [index] + rest }
		}
		return nil
	}

	private static func node(at path: [Int], in root: any XCUIElementSnapshot)
		-> any XCUIElementSnapshot
	{
		path.reduce(root) { $0.children[$1] }
	}

	private static func name(of type: XCUIElement.ElementType) -> String {
		switch type {
		case .button: "button"
		case .link: "link"
		case .switch: "switch"
		case .toggle: "toggle"
		case .textField: "textField"
		case .secureTextField: "secureTextField"
		case .textView: "textView"
		case .searchField: "searchField"
		default: "other"
		}
	}
}
