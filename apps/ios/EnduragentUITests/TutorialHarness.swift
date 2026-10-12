import EnduragentCoach
import XCTest

enum TutorialHarness {
	static let notice =
		"Training suggestions, not medical advice. Check with a doctor before big changes."
	static let weekQuestion = "What did my training look like this week?"
	static let remember = "Remember that I ride with a group on Saturdays"
	static let workout =
		"Give me a 60 minute endurance ride for tomorrow with two 10 minute tempo blocks"
	static let weekReply = "Tuesday sweet spot"
	static let rememberReply = "Noted. I'll remember you ride with a group on Saturdays."
	static let reviewReply = "Saturday group ride"
	static let newConversationStarted = "New conversation started."
	static let newConversationMemoryWarning =
		"New conversation started. Some recent details may not have been saved to coach memory."
	static let startedNewConversation = "You started a new conversation"
	static let earlierChat = "Earlier chat"
	static let readOnly = "Past conversations are read-only."
	static let done = "Done — Create workout \"Endurance with tempo\" on 6/16/1998."
	static let warmup = "Warmup"
	static let working = "Coach is working…"
	static let providerDown = "The model provider is having trouble — try again in a few minutes."
	static let accessRejected = "Your Credits couldn't be used. Restore purchases to continue."
	static let creditsExhausted =
		"You're out of Credits. You can switch to your OpenRouter account."
	static let savedUnverified =
		"I saved your information, but couldn't verify my response. Please try again."
	static let notConfigured = "Choose how the coach reaches a model to continue."
	static let locked = "Unlock your iPhone to continue. Your message is saved."
	static let buyCredits = "Buy Credits"
	static let restorePurchases = "Restore purchases"
	static let chooseAccessMethod = "Choose access method"
	static let rateLimitSevenSeconds = "Rate limited — please try again in ~7 seconds."
	static let rateLimitSixSeconds = "Rate limited — please try again in ~6 seconds."
	static let unknownFailure = "Sorry, something went wrong. Please try again."
	static let interruptedSomeSaved =
		"This reply stopped before it finished. Some information was saved first."
	static let interruptedNothingChanged =
		"This reply stopped before it finished. Nothing was changed."
	static let historyUnavailable = "Conversation history is temporarily unavailable."
	static let receivedBeforeClose = "Received before the app closed. Tap Try again to send it."
	static let notSent = "Not sent. Your draft is still here."
	static let tryAgain = "Try again"
	static let summaryHead = "[Previous conversation summary]"
	static let draft = "Is Thursday still on?"
	static let saturday = "How did Saturday go"
	static let finishedWhileLocked = "Finished while the phone was locked."
	static func launch(
		_ app: XCUIApplication, keychain: FixtureKeychainPolicy = .unlocked,
		coalescingMilliseconds: Int? = nil, host: String? = nil, language: String = "en",
		locale: String = "en_US", clock: String? = nil
	) {
		launch(
			app,
			arguments: FixtureArguments(
				keychain: keychain, coalescingMilliseconds: coalescingMilliseconds,
				host: host, language: language, locale: locale, clock: clock))
	}

	static func launch(_ app: XCUIApplication, arguments: FixtureArguments) {
		app.launchArguments = arguments.launchArguments
		app.launch()
		wait(app, until: .foreground)
	}

	static func launchUpgrade(_ app: XCUIApplication, store: FixtureStorePolicy) {
		launch(app, arguments: FixtureArguments(store: store, onboarded: true))
		agreeToProviderConsent(app)
	}

	static func relaunchKeepingStore(
		_ app: XCUIApplication, recovery: String = "readable", clock: String? = nil,
		keychain: FixtureKeychainPolicy? = nil, language: String? = nil, locale: String? = nil
	) {
		app.terminate()
		XCTAssertEqual(app.state, .notRunning)
		var arguments = FixtureArguments()
		do {
			try arguments.update(from: app.launchArguments)
		} catch {
			XCTFail("could not read fixture arguments: \(error)")
			return
		}
		arguments.store = .keep
		arguments.recovery = recovery
		if let clock { arguments.clock = clock }
		if let keychain { arguments.keychain = keychain }
		if let language { arguments.language = language }
		if let locale { arguments.locale = locale }
		launch(app, arguments: arguments)
	}

	static func attach(_ test: XCTestCase, name: String, app: XCUIApplication) {
		let attachment = XCTAttachment(screenshot: app.screenshot())
		attachment.name = name
		attachment.lifetime = .keepAlways
		test.add(attachment)
	}

	static func named(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
		app.descendants(matching: .any).matching(identifier: identifier).firstMatch
	}

	static func assertIconButtonWidth(_ button: XCUIElement) {
		XCTAssertLessThanOrEqual(button.frame.width, 44)
	}

	static func text(_ app: XCUIApplication, containing fragment: String) -> XCUIElement {
		app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", fragment)).firstMatch
	}

	static func notice(_ app: XCUIApplication, reading sentence: String) -> XCUIElement {
		app.staticTexts.matching(
			NSPredicate(format: "identifier == %@ AND label == %@", "chat.turn.notice", sentence)
		).firstMatch
	}

	enum Timeout: TimeInterval {
		case screen = 10
		case turn = 30
		case retry = 45
		case watchdog = 75
		case longTurn = 60
		case bulk = 600
		case probe = 2
		case cooldown = 5
		case records = 15
	}

	enum Condition {
		case exists
		case absent
		case hittable
		case enabled
		case foreground
		case value(String)

		func matches(_ element: XCUIElement) -> Bool {
			switch self {
			case .exists: element.exists
			case .absent: !element.exists
			case .hittable: element.exists && element.isHittable
			case .enabled: element.exists && element.isEnabled
			case .foreground: (element as? XCUIApplication)?.state == .runningForeground
			case .value(let expected): element.exists && element.value as? String == expected
			}
		}
	}

	@discardableResult
	static func wait(
		_ element: XCUIElement, until condition: Condition = .exists,
		within limit: Timeout = .screen, required: Bool = true,
		file: StaticString = #filePath, line: UInt = #line
	) -> Bool {
		wait(
			until: { condition.matches(element) }, within: limit, required: required,
			message: "\(element) did not reach \(condition)", file: file, line: line)
	}

	@discardableResult
	static func wait(
		until condition: @escaping () -> Bool, within limit: Timeout = .screen,
		required: Bool = true, message: String,
		file: StaticString = #filePath, line: UInt = #line
	) -> Bool {
		let deadline = ProcessInfo.processInfo.systemUptime + limit.rawValue
		var completed = condition()
		while !completed {
			let remaining = deadline - ProcessInfo.processInfo.systemUptime
			guard remaining > 0 else { break }
			RunLoop.current.run(until: Date(timeIntervalSinceNow: min(0.02, remaining)))
			completed = condition()
		}
		if required { XCTAssertTrue(completed, message, file: file, line: line) }
		return completed
	}

	@discardableResult
	static func waitForProgress(
		_ app: XCUIApplication, to goal: String, within limit: Timeout = .bulk,
		stoppedBy failure: XCUIElement? = nil, until reached: @escaping () -> Bool
	) -> Bool {
		var stop: String?
		let ended = wait(
			until: {
				if reached() { return true }
				if app.state != .runningForeground {
					stop = "the app is no longer in the foreground"
				} else if let failure, failure.exists {
					stop = "\(failure) appeared"
				}
				return stop != nil
			}, within: limit, required: false, message: goal)
		if let stop {
			XCTFail("\(goal) did not happen: \(stop)")
			return false
		}
		XCTAssertTrue(ended, "\(goal) did not happen")
		return ended
	}

	static func meanLuminance(_ screenshot: XCUIScreenshot) -> Double {
		guard let image = screenshot.image.cgImage else {
			XCTFail("the screenshot has no bitmap")
			return 1
		}
		let side = 16
		var pixels = [UInt8](repeating: 0, count: side * side * 4)
		let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
			guard
				let context = CGContext(
					data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8,
					bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
					bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
			else {
				return false
			}
			context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
			return true
		}
		XCTAssertTrue(drawn, "could not sample the screenshot")
		var total = 0.0
		for index in stride(from: 0, to: pixels.count, by: 4) {
			total +=
				0.2126 * Double(pixels[index]) + 0.7152 * Double(pixels[index + 1])
				+ 0.0722 * Double(pixels[index + 2])
		}
		return total / Double(side * side) / 255
	}

	static func waitForLabel(
		_ app: XCUIApplication, _ label: String, within limit: Timeout = .screen
	) {
		wait(text(app, containing: label), within: limit)
	}

	static func waitForWelcome(
		_ app: XCUIApplication, within limit: Timeout = .screen, language: LanguageTag = .en
	) {
		let welcome = named(app, "chat.welcome")
		wait(welcome, within: limit)
		let phrasebook = CatalogPhrasebook(tag: language)
		XCTAssertEqual(welcome.label, Welcome.text(in: phrasebook))
		let commands = welcome.label.split(separator: "\n").filter { $0.hasPrefix("/") }
		XCTAssertEqual(
			commands.map(String.init),
			SlashCommand.allCases.map { command in
				phrasebook.say(
					Catalog.chatWelcomeCommand,
					[
						"command": command.rawValue,
						"description": phrasebook.say(command.menuTitle),
					])
			})
	}

	static func startNewConversation(_ app: XCUIApplication, language: LanguageTag = .en) {
		let button = named(app, "chat.newConversation")
		wait(button, until: .hittable)
		button.tap()
		waitForWelcome(app, language: language)
	}

	static func openHistory(_ app: XCUIApplication) {
		let history = named(app, "chat.history")
		wait(history, until: .hittable)
		history.tap()
	}

	static func historyRows(_ app: XCUIApplication) -> XCUIElementQuery {
		app.descendants(matching: .any).matching(
			NSPredicate(format: "identifier BEGINSWITH %@", "history.row."))
	}

	static func send(_ app: XCUIApplication, _ text: String) {
		let composer = named(app, "chat.composer")
		wait(composer)
		composer.tap()
		composer.typeText(text)
		let send = named(app, "chat.send")
		wait(send)
		send.tap()
	}

	static func exchange(
		_ app: XCUIApplication, _ text: String, within limit: Timeout = .bulk
	) {
		let progress = named(app, "chat.turnProgress")
		wait(progress)
		let value = progress.value as? String ?? ""
		let fields = value.split(separator: " ")
		guard fields.count == 4, fields[0] == "turns", fields[2] == "settled",
			let count = Int(fields[1])
		else {
			XCTFail("invalid chat turn progress: \(value)")
			return
		}
		send(app, text)
		let settled = Condition.value("turns \(count + 1) settled \(count + 1)")
		waitForProgress(
			app, to: "\(progress) reaching \(settled)", within: limit,
			stoppedBy: named(app, "chat.composer.notSent")
		) { settled.matches(progress) }
	}

	static func sendLong(_ app: XCUIApplication) {
		exchange(app, "fixture:long")
		wait(text(app, containing: "Day 100. This week has"))
	}

	static func openSettings(_ app: XCUIApplication) {
		let settings = named(app, "chat.settings")
		guard wait(settings, until: .hittable) else { return }
		settings.tap()
		let credits = named(app, "settings.credits")
		waitForProgress(app, to: "Settings opening") { credits.exists }
	}

	static func openDebug(_ app: XCUIApplication) {
		openSettings(app)
		let debug = named(app, "settings.debug")
		wait(debug, until: .hittable)
		debug.tap()
		_ = debugRow(app, "debug.records")
	}

	static func fixtureControl(_ app: XCUIApplication, _ identifier: String) {
		openDebug(app)
		debugRow(app, identifier).tap()
		returnToChat(app)
	}

	static func openRecords(_ app: XCUIApplication) {
		openDebug(app)
		debugRow(app, "debug.records").tap()
		wait(named(app, "records.device"))
	}

	static func openCredentials(_ app: XCUIApplication) {
		openSettings(app)
		let connection = named(app, "settings.training")
		wait(connection, until: .hittable)
		connection.tap()
		wait(named(app, "training.edit"))
	}

	static func waitForIdentifier(
		_ app: XCUIApplication, _ identifier: String, reading label: String,
		within limit: Timeout = .screen
	) {
		let element = app.descendants(matching: .any).matching(
			NSPredicate(format: "identifier == %@ AND label == %@", identifier, label)
		).firstMatch
		wait(element, within: limit)
	}

	static func returnToChat(_ app: XCUIApplication, maximumBackSteps: Int = 4) {
		let settings = named(app, "chat.settings")
		for _ in 0..<maximumBackSteps {
			if settings.exists && settings.isHittable { break }
			let bar = app.navigationBars.firstMatch
			let title = bar.identifier
			let back = bar.buttons.firstMatch
			wait(back, until: .hittable)
			back.tap()
			wait(
				until: { app.navigationBars.firstMatch.identifier != title },
				message: "Back did not leave \(title)")
		}
		wait(settings, until: .hittable)
		wait(named(app, "chat.composer"))
	}

	static func historyHead(_ app: XCUIApplication) -> String {
		openDebug(app)
		let head = debugRow(app, "fixture.historyHead")
		let label = head.label
		returnToChat(app)
		return label
	}
}
