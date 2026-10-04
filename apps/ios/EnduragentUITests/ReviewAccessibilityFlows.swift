import EnduragentCoach
import XCTest

@MainActor
enum ReviewAccessibility {
	static func approval(_ test: XCTestCase, _ language: LanguageTag) {
		let arguments = FixtureArguments()
		let run = MatrixRun.begin(test, language, arguments: arguments, connected: false)
		TutorialHarness.exchange(run.app, TutorialHarness.workout)
		TutorialHarness.wait(run.named("chat.preview.add"), until: .enabled)
		reopenAtLargestText(run.app, arguments)
		let card = ReviewCardReading(run: run)
		TutorialHarness.wait(run.named("chat.preview.add"), until: .enabled, within: .turn)
		card.expect(notice: [], controls: [.cancel, .add], screen: "approval")
		card.captureContent()
		card.reach(.add).tap()
		card.expect(
			notice: [
				.text("chat.review.notice", run.say(Catalog.connectMissing)),
				.button("chat.review.connect", run.say(Catalog.onboardingConnectAction)),
			], controls: [.cancel, .add], screen: "approval-not-connected")
		card.reach(.cancel).tap()
		TutorialHarness.wait(run.named("chat.preview.cancel"), until: .absent)
		XCTAssertFalse(run.named("chat.preview.add").exists)
		XCTAssertFalse(run.named("chat.review.notice").exists)
		card.capture("cancelled")
	}

	static func uncertainSave(_ test: XCTestCase, _ language: LanguageTag) {
		let arguments = FixtureArguments(calendarSaveFault: .loseAnswerOnce)
		let run = MatrixRun.begin(test, language, arguments: arguments)
		TutorialHarness.exchange(run.app, TutorialHarness.workout)
		TutorialHarness.wait(run.named("chat.preview.add"), until: .enabled)
		run.tap("chat.preview.add")
		run.expect("chat.preview.notice", Catalog.reviewWritePending)
		TutorialHarness.wait(run.named("chat.preview.checkAgain"), until: .enabled)
		reopenAtLargestText(run.app, arguments)
		let card = ReviewCardReading(run: run)
		let pending = ReviewCardReading.Line.text(
			"chat.preview.notice", run.say(Catalog.reviewWritePending))
		TutorialHarness.wait(run.named("chat.preview.checkAgain"), until: .enabled, within: .turn)
		card.expect(notice: [pending], controls: [.checkAgain], screen: "save-uncertain")
		card.reach(.checkAgain).tap()
		TutorialHarness.wait(run.named("chat.preview.saveAgain"), until: .enabled)
		card.expect(
			notice: [pending], controls: [.checkAgain, .cancel, .saveAgain], screen: "save-again")
		card.reach(.saveAgain)
		card.reach(.cancel).tap()
		TutorialHarness.wait(run.named("chat.preview.cancel"), until: .absent)
		run.expect("chat.note", Catalog.reviewCancelledUnknown)
		card.capture("cancelled-unknown")
	}

	private static func reopenAtLargestText(_ app: XCUIApplication, _ arguments: FixtureArguments) {
		app.terminate()
		XCTAssertEqual(app.state, .notRunning)
		var reopened = arguments
		reopened.store = .keep
		reopened.textSize = .accessibilityXXXL
		TutorialHarness.launch(app, arguments: reopened)
	}
}

@MainActor
struct ReviewCardReading {
	let run: MatrixRun

	enum Control: String {
		case cancel = "chat.preview.cancel"
		case add = "chat.preview.add"
		case checkAgain = "chat.preview.checkAgain"
		case saveAgain = "chat.preview.saveAgain"

		var title: CatalogKey {
			switch self {
			case .cancel: Catalog.commonCancel
			case .add: Catalog.reviewAdd
			case .checkAgain: Catalog.setupTelegramCheckAgain
			case .saveAgain: Catalog.reviewSaveApprovedAgain
			}
		}
	}

	struct Line: Equatable {
		var type: XCUIElement.ElementType
		var identifier: String
		var label: String

		static func text(_ identifier: String, _ label: String) -> Line {
			Line(type: .staticText, identifier: identifier, label: label)
		}

		static func button(_ identifier: String, _ label: String) -> Line {
			Line(type: .button, identifier: identifier, label: label)
		}
	}

	private struct Spoken {
		var line: Line
		var frame: CGRect
		var enabled: Bool
	}

	static let copiedLabel = "Warmup ramp 1.5"
	static let minimumTarget: CGFloat = 44

	func expect(notice: [Line], controls: [Control], screen: String) {
		let buttons = controls.map { Line.button($0.rawValue, run.say($0.title)) }
		let expected = notice + buttons
		TutorialHarness.wait(
			until: { expected.allSatisfy { run.named($0.identifier).exists } },
			message: "\(name(screen)): the review did not show its notice and controls")
		let card: (items: [Spoken], frame: CGRect)
		do {
			card = try spoken()
		} catch {
			XCTFail("\(name(screen)): the review card could not be read: \(error)")
			return
		}
		let lines = card.items.map(\.line)
		let heard = lines.map { "\($0.identifier) \"\($0.label)\"" }.joined(separator: " | ")
		XCTAssertEqual(
			lines.first, .text("", run.say(Catalog.reviewTitle)),
			"\(name(screen)): VoiceOver does not start at the review title: \(heard)")
		XCTAssertTrue(
			lines.count > 1 && lines[1].type == .staticText
				&& lines[1].label.contains(Self.copiedLabel),
			"\(name(screen)): the workout does not follow the title: \(heard)")
		XCTAssertEqual(
			Array(lines.dropFirst(2)), expected,
			"\(name(screen)): the notice and the controls are not read in order after the workout: \(heard)"
		)
		for (earlier, later) in zip(card.items, card.items.dropFirst()) {
			XCTAssertTrue(
				Self.follows(earlier.frame, later.frame),
				"\(name(screen)): \"\(later.line.label)\" \(later.frame) is not after \"\(earlier.line.label)\" \(earlier.frame)"
			)
		}
		for item in card.items {
			XCTAssertTrue(
				item.frame.width > 0 && item.frame.minX >= card.frame.minX - 1
					&& item.frame.maxX <= card.frame.maxX + 1
					&& item.frame.maxX <= run.app.frame.maxX,
				"\(name(screen)): \"\(item.line.label)\" \(item.frame) leaves the card \(card.frame)"
			)
		}
		for item in card.items where item.line.type == .button {
			XCTAssertTrue(item.enabled, "\(name(screen)): \"\(item.line.label)\" is disabled")
			XCTAssertGreaterThanOrEqual(
				item.frame.height, Self.minimumTarget,
				"\(name(screen)): \"\(item.line.label)\" is not drawn at the largest text size")
		}
		audit(screen, inside: card.frame)
		capture(screen)
	}

	@discardableResult
	func reach(_ control: Control) -> XCUIElement {
		let button = run.named(control.rawValue)
		let transcript = run.named("chat.transcript")
		TutorialHarness.wait(
			until: {
				if button.exists && button.isHittable { return true }
				if button.frame.midY < transcript.frame.midY {
					transcript.swipeDown(velocity: .slow)
				} else {
					transcript.swipeUp(velocity: .slow)
				}
				return button.exists && button.isHittable
			}, message: "[\(run.language.rawValue)] \(control.rawValue) cannot be tapped")
		return button
	}

	func captureContent() {
		run.named("chat.transcript").swipeDown(velocity: .slow)
		capture("content")
	}

	func capture(_ screen: String) {
		TutorialHarness.attach(run.test, name: name(screen), app: run.app)
	}

	private func name(_ screen: String) -> String {
		"u9-6-\(run.language.rawValue)-\(screen)"
	}

	private func spoken() throws -> (items: [Spoken], frame: CGRect) {
		let cell = run.named("chat.transcript").cells.containing(
			NSPredicate(format: "identifier BEGINSWITH %@", "chat.preview.")
		).firstMatch
		let snapshot = try cell.snapshot()
		var items: [Spoken] = []
		Self.collect(snapshot, into: &items)
		return (items, snapshot.frame)
	}

	private func audit(_ screen: String, inside card: CGRect) {
		do {
			try run.app.performAccessibilityAudit(for: [.textClipped, .dynamicType, .hitRegion]) {
				issue in
				guard let element = issue.element, element.exists else { return true }
				return !card.insetBy(dx: -1, dy: -1).contains(element.frame)
			}
		} catch {
			XCTFail("\(name(screen)): the accessibility audit did not run: \(error)")
		}
	}

	private static func collect(_ node: any XCUIElementSnapshot, into items: inout [Spoken]) {
		let spoken = node.elementType == .staticText || node.elementType == .button
		if spoken && !node.label.isEmpty {
			items.append(
				Spoken(
					line: Line(
						type: node.elementType, identifier: node.identifier, label: node.label),
					frame: node.frame, enabled: node.isEnabled))
		}
		if node.elementType == .button { return }
		for child in node.children { collect(child, into: &items) }
	}

	private static func follows(_ earlier: CGRect, _ later: CGRect) -> Bool {
		later.minY >= earlier.maxY - 1
			|| (later.minX >= earlier.maxX - 1 && later.maxY > earlier.minY)
	}
}
