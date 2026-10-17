import EnduragentCoach
import XCTest

@MainActor
enum ReviewAccessibility {
	static func approval(_ test: XCTestCase, _ language: LanguageTag) {
		let arguments = FixtureArguments()
		let run = MatrixRun.begin(test, language, arguments: arguments)
		TutorialHarness.exchange(run.app, TutorialHarness.workout)
		TutorialHarness.wait(run.named("chat.preview.add"), until: .enabled)
		reopenAtLargestText(run.app, arguments)
		let card = ReviewCardReading(run: run)
		TutorialHarness.wait(run.named("chat.preview.add"), until: .enabled, within: .turn)
		card.expect(notice: [], controls: [.cancel, .add], screen: "approval")
		card.captureContent()
		card.reach(.add)
		card.reach(.cancel).tap()
		TutorialHarness.wait(run.named("chat.preview.cancel"), until: .absent)
		XCTAssertFalse(run.named("chat.preview.add").exists)
		XCTAssertFalse(run.named("chat.review.notice").exists)
		card.capture("cancelled")
	}

	static func unconfirmedChange(_ test: XCTestCase, _ language: LanguageTag) {
		let arguments = FixtureArguments(
			store: .unknownWriteBeforeUpgrade, onboarded: true, calendarReadFault: .failOnce)
		let run = MatrixRun.begin(test, language, arguments: arguments)
		TutorialHarness.wait(run.named("chat.preview.checkAgain"), until: .enabled)
		reopenAtLargestText(run.app, arguments)
		let card = ReviewCardReading(run: run, workout: ReviewCardReading.upgradedLabel)
		TutorialHarness.wait(run.named("chat.preview.checkAgain"), until: .enabled, within: .turn)
		card.expect(notice: [], controls: [.checkAgain, .cancel], screen: "unconfirmed")
		card.reach(.checkAgain).tap()
		TutorialHarness.wait(run.named("chat.preview.add"), until: .enabled)
		card.expect(
			notice: [.text("chat.review.notice", run.say(Catalog.workoutsStopped))],
			controls: [.cancel, .add], screen: "not-saved")
		card.reach(.add)
		card.reach(.cancel).tap()
		TutorialHarness.wait(run.named("chat.preview.cancel"), until: .absent)
		XCTAssertFalse(run.named("chat.preview.add").exists)
		card.capture("cancelled-unsaved")
	}

	static func blockedReview(_ test: XCTestCase, _ language: LanguageTag) {
		let arguments = FixtureArguments()
		let run = MatrixRun.begin(test, language, arguments: arguments)
		TutorialHarness.exchange(run.app, TutorialHarness.workout)
		TutorialHarness.wait(run.named("chat.preview.add"), until: .enabled)
		TutorialHarness.fixtureControl(run.app, "fixture.switchAthlete")
		run.tap("chat.preview.add")
		run.expect(
			"chat.review.notice", Catalog.reviewAccountChanged, ["service": "intervals.icu"])
		TutorialHarness.wait(run.named("chat.preview.add"), until: .absent)
		reopenAtLargestText(run.app, arguments)
		let card = ReviewCardReading(run: run)
		TutorialHarness.wait(run.named("chat.preview.cancel"), until: .enabled, within: .turn)
		card.expect(notice: [], controls: [.cancel], screen: "cancel-only")
		card.reach(.cancel).tap()
		TutorialHarness.wait(run.named("chat.preview.cancel"), until: .absent)
		card.capture("cancelled-blocked")
	}

	static func reopenAtLargestText(_ app: XCUIApplication, _ arguments: FixtureArguments) {
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
	var workout = Self.copiedLabel

	enum Control: String {
		case cancel = "chat.preview.cancel"
		case add = "chat.preview.add"
		case tryAgain = "chat.preview.tryAgain"
		case checkAgain = "chat.preview.checkAgain"

		var title: CatalogKey {
			switch self {
			case .cancel: Catalog.commonCancel
			case .add: Catalog.reviewAdd
			case .tryAgain: Catalog.chatTranscriptRetry
			case .checkAgain: Catalog.setupTelegramCheckAgain
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
	static let upgradedLabel = "190-225w"
	static let minimumTarget: CGFloat = 44

	func expect(notice: [Line], controls: [Control], screen: String) {
		let buttons = controls.map { Line.button($0.rawValue, run.say($0.title)) }
		TutorialHarness.wait(
			until: { (notice + buttons).allSatisfy { run.named($0.identifier).exists } },
			message: "\(name(screen)): the review did not show its notice and controls")
		let card: (items: [Spoken], frame: CGRect)
		let bar: (items: [Spoken], frame: CGRect)
		do {
			card = try spoken(transcriptCell())
			bar = try spoken(run.named("chat.review.bar"))
		} catch {
			XCTFail("\(name(screen)): the review could not be read: \(error)")
			return
		}
		let lines = card.items.map(\.line)
		let heard = (card.items + bar.items).map { "\($0.line.identifier) \"\($0.line.label)\"" }
			.joined(separator: " | ")
		XCTAssertEqual(
			lines.first, .text("chat.preview.title", run.say(Catalog.reviewTitle)),
			"\(name(screen)): VoiceOver does not start at the review title: \(heard)")
		let body = Array(lines.dropFirst())
		let workoutLines = body.prefix { $0.identifier.hasPrefix("chat.preview.card.") }
		XCTAssertTrue(
			workoutLines.first?.identifier == "chat.preview.card.title"
				&& workoutLines.allSatisfy { $0.type == .staticText }
				&& workoutLines.contains { $0.label.contains(workout) },
			"\(name(screen)): the workout does not follow the title: \(heard)")
		let rest = body.dropFirst(workoutLines.count)
		let kept = rest.prefix { $0.identifier.hasPrefix("chat.preview.kept") }
		XCTAssertEqual(
			Array(rest.dropFirst(kept.count)), notice,
			"\(name(screen)): the notice is not read after the workout: \(heard)")
		let question =
			controls.contains(.add)
			? [Line.text("chat.review.question", run.say(Catalog.workoutsBarQuestionAdd, count: 1))]
			: []
		let barLines = bar.items.map(\.line)
		XCTAssertEqual(
			barLines.first?.identifier, "chat.review.totals",
			"\(name(screen)): the bar does not start at the totals: \(heard)")
		XCTAssertEqual(
			Array(barLines.dropFirst()), question + buttons,
			"\(name(screen)): the question and the controls are not read in order after the totals: \(heard)"
		)
		for container in [card, bar] {
			expect(container, screen: screen)
		}
		audit(screen, inside: [card.frame, bar.frame])
		capture(screen)
	}

	private func expect(_ container: (items: [Spoken], frame: CGRect), screen: String) {
		for (earlier, later) in zip(container.items, container.items.dropFirst()) {
			XCTAssertTrue(
				Self.follows(earlier.frame, later.frame),
				"\(name(screen)): \"\(later.line.label)\" \(later.frame) is not after \"\(earlier.line.label)\" \(earlier.frame)"
			)
		}
		for item in container.items {
			XCTAssertTrue(
				item.frame.width > 0 && item.frame.minX >= container.frame.minX - 1
					&& item.frame.maxX <= container.frame.maxX + 1
					&& item.frame.maxX <= run.app.frame.maxX,
				"\(name(screen)): \"\(item.line.label)\" \(item.frame) leaves its container \(container.frame)"
			)
		}
		for item in container.items where item.line.type == .button {
			XCTAssertTrue(item.enabled, "\(name(screen)): \"\(item.line.label)\" is disabled")
			XCTAssertGreaterThanOrEqual(
				item.frame.height, Self.minimumTarget,
				"\(name(screen)): \"\(item.line.label)\" is not drawn at the largest text size")
		}
	}

	@discardableResult
	func reach(_ control: Control) -> XCUIElement {
		let button = run.named(control.rawValue)
		TutorialHarness.wait(
			until: {
				if button.exists && button.isHittable { return true }
				let band = TutorialHarness.transcriptBand(run.app)
				let upper = CGPoint(x: band.midX, y: band.minY + band.height * 0.2)
				let lower = CGPoint(x: band.midX, y: band.minY + band.height * 0.8)
				if button.frame.midY < band.midY {
					TutorialHarness.drag(run.app, from: upper, to: lower, pace: .fling)
				} else {
					TutorialHarness.drag(run.app, from: lower, to: upper, pace: .fling)
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
		"u9-2-\(run.language.rawValue)-\(screen)"
	}

	private func transcriptCell() -> XCUIElement {
		run.named("chat.transcript").cells.containing(
			NSPredicate(format: "identifier BEGINSWITH %@", "chat.preview.")
		).firstMatch
	}

	private func spoken(_ element: XCUIElement) throws -> (items: [Spoken], frame: CGRect) {
		let snapshot = try element.snapshot()
		var items: [Spoken] = []
		Self.collect(snapshot, into: &items)
		return (items, snapshot.frame)
	}

	private func audit(_ screen: String, inside frames: [CGRect]) {
		do {
			try run.app.performAccessibilityAudit(for: [.textClipped, .dynamicType, .hitRegion]) {
				issue in
				guard let element = issue.element, element.exists else { return true }
				return !frames.contains { $0.insetBy(dx: -1, dy: -1).contains(element.frame) }
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
		later.minY >= earlier.maxY - 2
			|| (later.minX >= earlier.maxX - 2 && later.maxY > earlier.minY)
	}
}
