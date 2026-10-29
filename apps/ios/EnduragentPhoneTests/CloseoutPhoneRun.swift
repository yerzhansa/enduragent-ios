import EnduragentCoach
import XCTest

final class CloseoutPhoneRun: XCTestCase {
	static let lapTable = "the lap table is cut off"
	static let questions = [
		"What is an endurance ride?", "What is a recovery ride?", "What does the talk test mean?",
		"How long should my warm-up be?",
	]

	@MainActor var app: XCUIApplication {
		XCUIApplication(bundleIdentifier: "icu.enduragent.app")
	}
	let english = CatalogPhrasebook(tag: .en)
	var messagesRemaining = 0
	var asked = 0
	var log: [String] = []

	override func tearDown() {
		let attachment = XCTAttachment(string: log.joined(separator: "\n"))
		attachment.name = "closeout-phone-actions"
		attachment.lifetime = .keepAlways
		add(attachment)
	}

	@MainActor
	func testCloseoutPhoneRun() throws {
		continueAfterFailure = false
		let environment = ProcessInfo.processInfo.environment
		guard
			let steps = PlannedPhoneStep.steps(in: environment[PlannedPhoneStep.variable] ?? "")
		else {
			throw PhoneRunBlocked(reason: "Run CloseoutPhoneRun through phone-check closeout.")
		}
		let ids = steps.map(\.id).joined(separator: ", ")
		let planned = steps.reduce(0) { $0 + $1.planned }
		guard let value = environment["ENDURAGENT_PHONE_MESSAGE_BUDGET"],
			let budget = Int(value), budget >= planned
		else {
			throw PhoneRunBlocked(
				reason:
					"Ask the operator for this invocation's message budget through phone-check closeout. \(ids) need \(planned) message actions."
			)
		}
		messagesRemaining = budget
		log.append("Approved message budget \(budget) for \(ids).")
		try launch()
		for step in steps {
			log.append("\(step.id) starts.")
			switch step.id {
			case "closeout/about": try about()
			case "closeout/feedback": try feedback()
			case "closeout/language": try language()
			default: throw PhoneRunBlocked(reason: "CloseoutPhoneRun has no step \(step.id).")
			}
			shot("\(step.id.replacingOccurrences(of: "/", with: "-"))-done")
		}
		#if targetEnvironment(simulator)
			TutorialHarness.openDebug(app)
			XCTAssertEqual(
				TutorialHarness.debugRow(app, "fixture.feedbackRequests").label,
				"0 feedback requests")
			TutorialHarness.returnToChat(app)
		#endif
	}

	@MainActor
	private func launch() throws {
		#if targetEnvironment(simulator)
			TutorialHarness.launch(app, arguments: FixtureArguments())
			TutorialHarness.completeOnboarding(app)
		#else
			guard app.launchArguments.isEmpty, app.launchEnvironment.isEmpty else {
				throw PhoneRunBlocked(reason: "Use a plain phone launch, without fixtures.")
			}
			app.launch()
			TutorialHarness.wait(app, until: .foreground, within: .turn)
		#endif
		shot("launch")
		try requireChat()
	}

	@MainActor
	private func about() throws {
		TutorialHarness.openSettings(app)
		try open("settings.about", titled: english.say(Catalog.aboutTitle))
		try expectAbout()
		let link = element("about.privacyPolicy")
		XCTAssertEqual(link.label, english.say(Catalog.aboutPrivacyPolicy))
		shot("about")
		link.tap()
		log.append("Tapped about.privacyPolicy.")
		let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
		TutorialHarness.wait(safari, until: .foreground, within: .turn)
		shot("about-privacy-policy")
		app.activate()
		TutorialHarness.wait(app, until: .foreground)
		TutorialHarness.wait(
			until: { safari.state != .runningForeground }, message: "Safari stayed in front.")
		TutorialHarness.returnToChat(app)
		try command("/version")
		try expectAbout()
		shot("about-from-version")
		TutorialHarness.returnToChat(app)
	}

	@MainActor
	private func expectAbout() throws {
		TutorialHarness.waitForIdentifier(app, "about.value.name", reading: "Enduragent")
		let version = element("about.version")
		TutorialHarness.wait(version)
		guard version.label == english.say(Catalog.aboutVersion) else {
			throw PhoneRunBlocked(reason: "About shows no version line: \(version.label).")
		}
		let value = element("about.value.version")
		TutorialHarness.wait(value)
		let shown = value.label
		XCTAssertNotNil(
			shown.wholeMatch(of: /\d+(\.\d+)+ \(\d+\)/), "About shows the version and build.")
		log.append("About shows Enduragent \(shown).")
	}

	@MainActor
	private func feedback() throws {
		TutorialHarness.openSettings(app)
		try open("settings.feedback", titled: english.say(Catalog.feedbackTitle))
		let field = element("feedback.field")
		TutorialHarness.wait(field)
		shot("feedback-from-row")
		TutorialHarness.returnToChat(app)
		try command("/feedback " + Self.lapTable)
		TutorialHarness.wait(field, until: .value(Self.lapTable))
		shot("feedback-from-command")
		try clear(field)
		try sendThroughGate(expecting: [english.say(Catalog.feedbackRefusedEmpty)])
		shot("feedback-empty-refused")
		try paste(String(repeating: "a", count: FeedbackStepGuard.limit + 1), into: field)
		TutorialHarness.wait(
			until: { (field.value as? String)?.count == FeedbackStepGuard.limit + 1 },
			message: "The pasted note is not 4,001 characters.")
		try sendThroughGate(expecting: [
			english.say(Catalog.feedbackRefusedTooLong, ["limit": "4,000"])
		])
		shot("feedback-too-long-refused")
		try clear(field)
		try paste("\u{0}", into: field)
		let entered = (field.value as? String ?? "").unicodeScalars.contains("\u{0}")
		if entered {
			log.append("NUL entered.")
			try sendThroughGate(expecting: [
				english.say(Catalog.feedbackRefusedInvalidCharacter),
				english.say(Catalog.feedbackRefusedEmpty),
			])
			try clear(field)
		} else {
			try clear(field)
			log.append("NUL not enterable.")
		}
		shot("feedback-nul")
		TutorialHarness.returnToChat(app)
	}

	@MainActor
	private func sendThroughGate(expecting sentences: [String]) throws {
		try FeedbackSendGate.tapSend(in: app)
		log.append("Tapped Send through the guard.")
		let outcome = element("feedback.outcome")
		TutorialHarness.wait(
			until: { outcome.exists && sentences.contains(outcome.label) },
			message: "The refusal did not show: \(sentences.joined(separator: " or ")).")
		log.append("Refused: \(outcome.label)")
	}

	@MainActor
	private func language() throws {
		let french = LanguageTag.fr.phrasebook
		try choose("fr")
		try expectSupport(in: french)
		TutorialHarness.returnToChat(app)
		try ask()
		try ask()
		try choose("automatic")
		#if targetEnvironment(simulator)
			let launched = [FixtureArguments().language]
		#else
			let launched = Locale.preferredLanguages
		#endif
		let automatic = DisplayLocale(
			preference: .automatic, preferredLanguages: launched,
			regionalConventions: Locale.current
		).phrasebook
		try expectSupport(in: automatic)
		TutorialHarness.returnToChat(app)
		try ask()
		try ask()
	}

	@MainActor
	private func choose(_ id: String) throws {
		TutorialHarness.openSettings(app)
		let row = element("settings.language")
		TutorialHarness.scroll(app, to: row)
		row.tap()
		let choice = element("language.choice.\(id)")
		TutorialHarness.wait(choice, until: .hittable)
		choice.tap()
		TutorialHarness.wait(
			until: { choice.isSelected && !self.element("language.saveFailed").exists },
			message: "Language \(id) was not saved.")
		log.append("Chose language \(id).")
		shot("language-\(id)")
		element("language.close").tap()
		TutorialHarness.wait(element("language.close"), until: .absent)
	}

	@MainActor
	private func expectSupport(in phrasebook: CatalogPhrasebook) throws {
		TutorialHarness.wait(
			TutorialHarness.text(app, containing: phrasebook.say(Catalog.settingsSupportTitle)))
		let screens = [
			("settings.feedback", Catalog.feedbackTitle, "feedback.prompt", Catalog.feedbackPrompt),
			(
				"settings.diagnostics", Catalog.diagnosticsTitle, "diagnostics.explanation",
				Catalog.diagnosticsExplanation
			),
			(
				"settings.about", Catalog.aboutTitle, "about.privacyPolicy",
				Catalog.aboutPrivacyPolicy
			),
		]
		for (row, title, content, sentence) in screens {
			XCTAssertEqual(element(row).label, phrasebook.say(title))
			try open(row, titled: phrasebook.say(title))
			TutorialHarness.waitForIdentifier(app, content, reading: phrasebook.say(sentence))
			shot("\(row)-\(phrasebook.say(title))")
			app.navigationBars.buttons.element(boundBy: 0).tap()
			TutorialHarness.wait(element(row), until: .hittable)
		}
		log.append("Support reads \(phrasebook.say(Catalog.settingsSupportTitle)).")
	}

	@MainActor
	private func open(_ row: String, titled title: String) throws {
		let link = element(row)
		TutorialHarness.scroll(app, to: link)
		link.tap()
		log.append("Opened \(row).")
		TutorialHarness.wait(
			until: { self.app.navigationBars.firstMatch.identifier == title },
			message: "\(row) did not open \(title).")
	}

	@MainActor
	private func command(_ text: String) throws {
		try requireChat()
		TutorialHarness.send(app, text)
		log.append("Sent the command \(text.split(separator: " ")[0]).")
	}

	@MainActor
	private func ask() throws {
		try requireChat()
		guard asked < Self.questions.count, messagesRemaining > 0 else {
			throw PhoneRunBlocked(reason: "The approved message budget is exhausted.")
		}
		let composer = element("chat.composer")
		guard composer.value as? String ?? "" == "" else {
			throw PhoneRunBlocked(reason: "The operator's draft is still in the composer.")
		}
		let question = Self.questions[asked]
		asked += 1
		messagesRemaining -= 1
		log.append("Message action chat.send. Budget remaining \(messagesRemaining).")
		TutorialHarness.exchange(app, question)
		shot("language-reply-\(asked)")
	}

	@MainActor
	private func paste(_ note: String, into field: XCUIElement) throws {
		UIPasteboard.general.string = note
		field.tap()
		field.press(forDuration: 1.2)
		let paste = editAction("Paste")
		TutorialHarness.wait(paste, until: .hittable)
		paste.tap()
		log.append("Pasted a note of \(note.unicodeScalars.count) characters.")
	}

	@MainActor
	private func clear(_ field: XCUIElement) throws {
		guard !FeedbackSendGate.readsEmpty(field) else { return }
		guard let shown = field.value as? String else {
			throw PhoneRunBlocked(reason: "The note field shows no text.")
		}
		if shown.count > 200 {
			field.press(forDuration: 1.2)
			let selectAll = editAction("Select All")
			if !selectAll.waitForExistence(timeout: TutorialHarness.Timeout.probe.rawValue) {
				field.tap()
			}
			TutorialHarness.wait(selectAll, until: .hittable)
			selectAll.tap()
			field.typeText(XCUIKeyboardKey.delete.rawValue)
		} else {
			field.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.9)).tap()
			field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: shown.count))
		}
		TutorialHarness.wait(
			until: { FeedbackSendGate.readsEmpty(field) }, message: "The note did not clear.")
		log.append("Cleared the note.")
	}

	@MainActor
	private func editAction(_ label: String) -> XCUIElement {
		app.descendants(matching: .any).matching(
			NSPredicate(
				format: "label == %@ AND (elementType == %d OR elementType == %d)", label,
				XCUIElement.ElementType.menuItem.rawValue, XCUIElement.ElementType.button.rawValue)
		).firstMatch
	}

	@MainActor
	private func requireChat() throws {
		let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
		guard app.state == .runningForeground, !app.alerts.firstMatch.exists,
			!springboard.alerts.firstMatch.exists,
			TutorialHarness.wait(element("chat.composer"), required: false),
			!["consent.accept", "consent.resume", "notice.continue", "connect.apiKey"]
				.contains(where: { element($0).exists })
		else {
			shot("operator-required")
			throw PhoneRunBlocked(
				reason: "Stop. The operator must unlock, sign in, or accept consent on the phone.")
		}
	}

	@MainActor
	private func element(_ identifier: String) -> XCUIElement {
		TutorialHarness.named(app, identifier)
	}

	@MainActor
	private func shot(_ name: String) {
		let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
		attachment.name = name
		attachment.lifetime = .keepAlways
		add(attachment)
	}
}
