import EnduragentCoach
import XCTest

@MainActor
struct PlanSaveCardScreen {
	struct Expected: Equatable {
		var identifier: String
		var label: String?
	}

	let run: MatrixRun
	let size: PlanCardSize

	static let card = "chat.planSave.card"
	static let bar = "chat.planSave.bar"
	static let save = "chat.planSave.save"
	static let cancel = "chat.planSave.cancel"

	static func begin(
		_ test: XCTestCase, _ language: LanguageTag, _ size: PlanCardSize,
		arguments: FixtureArguments = FixtureArguments()
	) -> PlanSaveCardScreen {
		PlanSaveCardScreen(run: MatrixRun.begin(test, language, arguments: arguments), size: size)
	}

	func exchange(_ text: String) {
		TutorialHarness.exchange(run.app, text)
	}

	func relaunch(at size: PlanCardSize, clock: String? = nil) {
		run.app.terminate()
		XCTAssertEqual(run.app.state, .notRunning)
		var arguments = FixtureArguments()
		do {
			try arguments.update(from: run.app.launchArguments)
		} catch {
			XCTFail("\(name("relaunch")): the fixture arguments could not be read: \(error)")
			return
		}
		arguments.store = .keep
		arguments.textSize = size.textSize
		if let clock { arguments.clock = clock }
		TutorialHarness.launch(run.app, arguments: arguments)
	}

	func show() {
		if size == .largest { relaunch(at: .largest) }
	}

	func card(_ plan: PlanFixture) -> XCUIElement {
		run.named("chat.transcript").descendants(matching: .any).matching(identifier: Self.card)
			.containing(
				NSPredicate(
					format: "identifier == %@ AND label == %@", "chat.planSave.name", plan.name)
			).firstMatch
	}

	func part(_ identifier: String, of plan: PlanFixture) -> XCUIElement {
		card(plan).descendants(matching: .any).matching(identifier: identifier).firstMatch
	}

	func title(of plan: PlanFixture) -> XCUIElement? {
		let card = card(plan)
		guard card.exists else { return nil }
		let top = card.frame.minY
		return run.named("chat.transcript").descendants(matching: .any)
			.matching(identifier: "chat.planSave.title").allElementsBoundByIndex
			.filter { $0.frame.maxY <= top + 2 }
			.max { $0.frame.maxY < $1.frame.maxY }
	}

	func waitForCard(
		_ plan: PlanFixture, from direction: TutorialHarness.ScrollDirection = .down
	) {
		let card = card(plan)
		if !card.exists {
			ReviewCardScreen.reveal(run.app, card, direction: direction)
		}
		TutorialHarness.wait(card, within: .turn)
	}

	func expectControls(_ shown: Bool, of plan: PlanFixture, _ screen: String) {
		let reading = ReviewCardReading(run: run)
		if shown {
			if size == .largest { reading.reach(Self.save) }
			for identifier in [Self.save, Self.cancel] {
				TutorialHarness.wait(run.named(identifier), until: .enabled, within: .turn)
			}
			return
		}
		let state = part("chat.planSave.state", of: plan)
		TutorialHarness.wait(state, within: .turn)
		if size == .largest { TutorialHarness.bringIntoTranscript(run.app, state) }
		for identifier in [Self.save, Self.cancel, Self.bar] {
			TutorialHarness.wait(run.named(identifier), until: .absent, within: .turn)
		}
	}

	func expectLine(
		_ identifier: String, of plan: PlanFixture, reading label: String?, _ screen: String
	) {
		let line = part(identifier, of: plan)
		guard let label else {
			XCTAssertFalse(line.exists, "\(name(screen)): \(identifier) should be absent")
			return
		}
		TutorialHarness.wait(
			until: { line.exists && line.label == label },
			message:
				"\(name(screen)): \(identifier) reads \"\(line.exists ? line.label : "nothing")\", not \"\(label)\""
		)
	}

	func expectState(_ key: CatalogKey?, of plan: PlanFixture, _ screen: String) {
		expectLine("chat.planSave.state", of: plan, reading: key.map { run.say($0) }, screen)
	}

	func expectAnswer(
		_ key: CatalogKey?, _ vars: [String: String] = [:], of plan: PlanFixture, _ screen: String
	) {
		expectLine("chat.planSave.answer", of: plan, reading: key.map { run.say($0, vars) }, screen)
	}

	func expectOpening(_ plan: PlanFixture, newest: String?, _ screen: String) {
		TutorialHarness.wait(
			until: {
				let band = TutorialHarness.transcriptBand(run.app)
				guard let title = title(of: plan), title.frame.minY >= band.minY,
					title.frame.maxY <= band.maxY
				else { return false }
				guard let newest else { return true }
				let messages = run.named("chat.transcript").staticTexts
					.matching(NSPredicate(format: "label CONTAINS %@", newest))
					.allElementsBoundByIndex
				guard let message = messages.last else { return false }
				return message.frame.maxY > band.minY && message.frame.minY < band.maxY
			},
			message:
				"\(name(screen)): the chat did not open with the newest message and the card's title on screen"
		)
		capture("\(screen)-opening")
	}

	func expectBar(under plan: PlanFixture, _ screen: String) {
		if size == .largest { ReviewCardReading(run: run).reach(Self.save) }
		let bar = run.named(Self.bar)
		TutorialHarness.wait(bar, within: .turn)
		let inTranscript = run.named("chat.transcript").descendants(matching: .any)
			.matching(identifier: Self.bar).firstMatch
		switch size {
		case .standard:
			XCTAssertFalse(
				inTranscript.exists,
				"\(name(screen)): at the default size the bar is in the transcript")
			XCTAssertLessThanOrEqual(
				bar.frame.maxY, run.named("chat.composer.container").frame.minY + 1,
				"\(name(screen)): the bar is not docked above the composer")
		case .largest:
			XCTAssertTrue(
				inTranscript.exists,
				"\(name(screen)): at the largest text size the bar is not in the transcript")
			XCTAssertEqual(
				run.app.descendants(matching: .any).matching(identifier: Self.bar).count, 1,
				"\(name(screen)): at the largest text size a bar is also docked above the composer")
			let card = card(plan)
			XCTAssertTrue(
				card.exists && ReviewCardReading.follows(card.frame, inTranscript.frame)
					&& inTranscript.frame.minY - card.frame.maxY < 40,
				"\(name(screen)): the bar \(inTranscript.frame) is not directly under its card \(card.frame)"
			)
		}
	}

	func expectWholeButtons(_ screen: String) {
		let reading = ReviewCardReading(run: run)
		for identifier in [Self.save, Self.cancel] {
			let button = size == .largest ? reading.reach(identifier) : run.named(identifier)
			TutorialHarness.wait(button, until: .hittable)
			let frame = button.frame
			XCTAssertTrue(
				frame.minX >= run.app.frame.minX - 1 && frame.maxX <= run.app.frame.maxX + 1
					&& frame.height >= ReviewCardReading.minimumTarget,
				"\(name(screen)): \(identifier) \(frame) is not whole on screen")
		}
		let save = run.named(Self.save).frame
		let cancel = run.named(Self.cancel).frame
		XCTAssertTrue(
			ReviewCardReading.follows(save, cancel),
			"\(name(screen)): Cancel \(cancel) is neither beside nor under Save plan \(save)")
	}

	func expected(
		_ plan: PlanFixture, preparedEarlier: Bool = false, replaces: String? = nil,
		state: CatalogKey? = nil, controls: Bool = true
	) -> [Expected] {
		var lines = [
			Expected(identifier: "chat.planSave.title", label: run.say(Catalog.chatPlanSaveTitle))
		]
		if preparedEarlier {
			lines.append(
				Expected(
					identifier: "chat.planSave.preparedEarlier",
					label: run.say(Catalog.workoutsPreparedEarlier)))
		}
		lines.append(Expected(identifier: "chat.planSave.name", label: plan.name))
		if let goal = plan.goal {
			lines += pair("goal", Catalog.planViewEndedGoal, goal)
		}
		if let weeks = plan.weeks {
			lines += pair("duration", Catalog.chatPlanReferenceDuration, weeksText(weeks))
		}
		for (index, phase) in plan.phases.enumerated() {
			lines.append(
				Expected(
					identifier: "chat.planSave.phase",
					label: run.say(Catalog.chatPlanSavePhase, ["number": String(index + 1)])))
			if let focus = phase.focus {
				lines += pair("focus", Catalog.chatPlanSaveFocusLabel, run.say(focus))
			}
			if let weeks = phase.weeks {
				lines += pair("weeks", Catalog.chatPlanReferenceDuration, weeksText(weeks))
			}
			if phase.hours {
				lines += pair("hours", Catalog.chatPlanSaveWeeklyHours, nil)
			}
		}
		if let replaces {
			lines.append(
				Expected(
					identifier: "chat.planSave.replaces",
					label: run.say(Catalog.chatPlanSaveReplaces, ["name": replaces])))
		}
		if let state {
			lines.append(Expected(identifier: "chat.planSave.state", label: run.say(state)))
		}
		if controls {
			lines += [
				Expected(identifier: Self.save, label: run.say(Catalog.chatPlanSaveSave)),
				Expected(identifier: Self.cancel, label: run.say(Catalog.commonCancel)),
			]
		}
		return lines
	}

	func expectReadingOrder(_ plan: PlanFixture, _ expected: [Expected], _ screen: String) {
		revealTitle(of: plan)
		guard let title = title(of: plan) else {
			XCTFail("\(name(screen)): the card's title is not in the transcript")
			return
		}
		TutorialHarness.bringIntoTranscript(run.app, title)
		var heard: [ReviewCardReading.Spoken]
		do {
			heard = try spoken(run.named("chat.transcript"), from: title.frame.minY)
				.filter { $0.line.identifier != Self.save && $0.line.identifier != Self.cancel }
			if size == .largest { ReviewCardReading(run: run).reach(Self.save) }
			heard += try spoken(run.named(Self.bar), from: nil)
		} catch {
			XCTFail("\(name(screen)): the card could not be read: \(error)")
			return
		}
		let order = heard.map { "\($0.line.identifier) \"\($0.line.label)\"" }
			.joined(separator: " | ")
		XCTAssertEqual(
			heard.map(\.line.identifier), expected.map(\.identifier),
			"\(name(screen)): VoiceOver does not read the card in order: \(order)")
		for (line, wanted) in zip(heard.map(\.line), expected) {
			guard let label = wanted.label else { continue }
			XCTAssertEqual(
				line.label, label, "\(name(screen)): \(wanted.identifier) reads wrong: \(order)")
		}
	}

	func revealTitle(of plan: PlanFixture) {
		TutorialHarness.wait(
			until: {
				if title(of: plan) != nil { return true }
				let band = TutorialHarness.transcriptBand(run.app)
				let reach = band.height * 0.3
				TutorialHarness.drag(
					run.app, from: CGPoint(x: band.midX, y: band.midY - reach),
					to: CGPoint(x: band.midX, y: band.midY + reach), pace: .steady)
				return false
			}, within: .bulk,
			message: "\(name("title")): the card's title never came into the transcript"
		)
	}

	func expectValuesUnderLabels(of plan: PlanFixture, _ screen: String) {
		let card = card(plan)
		for pair in ["goal", "duration", "focus", "weeks", "hours"] {
			let labels = card.descendants(matching: .any)
				.matching(identifier: "chat.planSave.\(pair).label").allElementsBoundByIndex
			let values = card.descendants(matching: .any)
				.matching(identifier: "chat.planSave.\(pair).value").allElementsBoundByIndex
			XCTAssertEqual(labels.count, values.count, "\(name(screen)): \(pair) pairs differ")
			for (label, value) in zip(labels, values) {
				let under = value.frame.minY >= label.frame.maxY - 2
				XCTAssertEqual(
					under, size == .largest,
					"\(name(screen)): \(pair) value \(value.frame) and label \(label.frame) are laid out wrong"
				)
			}
		}
	}

	func expectWholeName(_ plan: PlanFixture, _ screen: String) {
		let name = part("chat.planSave.name", of: plan)
		TutorialHarness.wait(name)
		XCTAssertEqual(name.label, plan.name, "\(self.name(screen)): the name is cut")
		let line = run.named("chat.planSave.goal.label").frame.height
		XCTAssertGreaterThan(
			name.frame.height, line * 1.5, "\(self.name(screen)): the long name is on one line")
	}

	func expectDisclaimerLast(_ screen: String) {
		guard size == .largest else { return }
		ReviewCardReading(run: run).expectDisclaimerEndsTheTranscript("u7-1-\(screen)")
	}

	func audit(_ screen: String) {
		do {
			try run.app.performAccessibilityAudit(for: [.textClipped]) { issue in
				guard let element = issue.element, element.exists else { return true }
				return !element.identifier.hasPrefix("chat.planSave.")
			}
		} catch {
			XCTFail("\(name(screen)): the accessibility audit did not run: \(error)")
		}
	}

	func capture(_ screen: String) {
		TutorialHarness.attach(run.test, name: name(screen), app: run.app)
	}

	func name(_ screen: String) -> String {
		"u7-1-\(run.language.rawValue)-\(size.rawValue)-\(screen)"
	}

	private func pair(_ id: String, _ label: CatalogKey, _ value: String?) -> [Expected] {
		[
			Expected(identifier: "chat.planSave.\(id).label", label: run.say(label)),
			Expected(identifier: "chat.planSave.\(id).value", label: value),
		]
	}

	private func weeksText(_ weeks: Int) -> String {
		run.say(Catalog.planViewDraftWeeks, count: weeks, ["weeks": String(weeks)])
	}

	private func spoken(_ element: XCUIElement, from top: CGFloat?) throws
		-> [ReviewCardReading.Spoken]
	{
		var items: [ReviewCardReading.Spoken] = []
		ReviewCardReading.collect(try element.snapshot(), into: &items, leaving: nil)
		return items.filter { item in
			item.line.identifier.hasPrefix("chat.planSave.")
				&& item.line.identifier != "chat.planSave.answer"
				&& top.map { item.frame.minY >= $0 - 1 } ?? true
		}
	}
}
