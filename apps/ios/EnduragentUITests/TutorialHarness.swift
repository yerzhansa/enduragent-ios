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
	static let welcomeHead = "Welcome to Cycling Coach!"
	static let syncLine = "/sync — Force-refresh training data from intervals.icu"
	static let newConversationStarted = "New conversation started."
	static let newConversationMemoryWarning =
		"New conversation started. Some recent details may not have been saved to coach memory."
	static let startedNewConversation = "You started a new conversation"
	static let earlierChat = "Earlier chat"
	static let readOnly = "Past conversations are read-only."
	static let done = "Done — Create workout \"Endurance with tempo\" on 1998-06-16."
	static let warmup = "Warmup"
	static let working = "Coach is working…"
	static let providerDown = "The model provider is having trouble — try again in a few minutes."
	static let accessRejected = "Your Credits couldn't be used. Restore purchases to continue."
	static let creditsExhausted =
		"You're out of Credits. Buy more, or switch to your OpenRouter account."
	static let savedUnverified =
		"I saved your information, but couldn't verify my response. Please try again."
	static let notConfigured = "Choose how the coach reaches a model to continue."
	static let locked = "Unlock your iPhone to continue. Your message is saved."
	static let buyCredits = "Buy Credits"
	static let restorePurchases = "Restore purchases"
	static let chooseAccessMethod = "Choose access method"
	static let rateLimitSevenSeconds = "Rate limited — please try again in ~7 seconds."
	static let rateLimitTwoMinutes = "Rate limited — please try again in ~2 minutes."
	static let rateLimitSixSeconds = "Rate limited — please try again in ~6 seconds."
	static let unknownFailure = "Sorry, something went wrong. Please try again."
	static let interruptedSomeSaved =
		"This reply stopped before it finished. Some information was saved first."
	static let interruptedNothingChanged =
		"This reply stopped before it finished. Nothing was changed."
	static let historyUnavailable = "Conversation history is temporarily unavailable."
	static let receivedBeforeClose = "Received before the app closed. Tap Try again to send it."
	static let notSent = "Not sent. Your draft is still here."
	static let keptCurrentKey = "Kept the current key."
	static let previousKeyKept = "Previous key kept."
	static let tryAgain = "Try again"
	static let summaryHead = "[Previous conversation summary]"
	static let draft = "Is Thursday still on?"
	static let saturday = "How did Saturday go"
	static let finishedWhileLocked = "Finished while the phone was locked."
	static let storeArgument = "-EnduragentFixtureStore"
	static let keychainArgument = "-EnduragentFixtureKeychain"
	static let coalescingArgument = "-EnduragentFixtureCoalescing"
	static let recoveryArgument = "-EnduragentFixtureRecovery"
	static let hostArgument = "-EnduragentFixtureHost"
	static let clockArgument = "-EnduragentFixtureClock"

	static func launch(
		_ app: XCUIApplication, keychain: String? = nil,
		coalescingMilliseconds: Int? = nil, host: String? = nil, language: String = "en",
		locale: String = "en_US", clock: String? = nil
	) {
		app.launchArguments = [
			"-EnduragentFixture", "first-week", storeArgument, "fresh",
			"-AppleLanguages", "(\(language))", "-AppleLocale", locale,
		]
		if let keychain {
			app.launchArguments += [keychainArgument, keychain]
		}
		if let coalescingMilliseconds {
			app.launchArguments += [coalescingArgument, String(coalescingMilliseconds)]
		}
		if let host {
			app.launchArguments += [hostArgument, host]
		}
		if let clock {
			app.launchArguments += [clockArgument, clock]
		}
		app.launch()
	}

	static func launchKeepingStore(
		_ app: XCUIApplication, expecting element: XCUIElement, arguments: [String] = []
	) throws {
		app.launchArguments =
			[
				"-EnduragentFixture", "first-week", storeArgument, "keep",
				"-AppleLanguages", "(en)", "-AppleLocale", "en_US",
			] + arguments
		app.launch()
		XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
		if named(app, "consent.accept").waitForExistence(timeout: 3) {
			agreeToProviderConsent(app)
		}
		guard named(app, "chat.sidebar").waitForExistence(timeout: 10) else {
			throw XCTSkip(v1StoreMissing)
		}
		openRecords(app)
		let written = recordCount(app, "assistantMessage") != nil
		closeMenu(app)
		guard written else { throw XCTSkip(v1StoreMissing) }
		wait(element)
	}

	private static let v1StoreMissing =
		"needs a fixture store a v1 build left; see Upgrade proofs in the verify skill"

	static func relaunchKeepingStore(
		_ app: XCUIApplication, recovery: String = "readable", clock: String? = nil
	) {
		app.terminate()
		XCTAssertEqual(app.state, .notRunning)
		guard let index = app.launchArguments.firstIndex(of: storeArgument),
			app.launchArguments.indices.contains(index + 1)
		else {
			XCTFail("launch arguments carry no \(storeArgument)")
			return
		}
		app.launchArguments[index + 1] = "keep"
		if let flag = app.launchArguments.firstIndex(of: recoveryArgument) {
			app.launchArguments.removeSubrange(flag...(flag + 1))
		}
		app.launchArguments += [recoveryArgument, recovery]
		if let clock {
			if let flag = app.launchArguments.firstIndex(of: clockArgument) {
				app.launchArguments.removeSubrange(flag...(flag + 1))
			}
			app.launchArguments += [clockArgument, clock]
		}
		app.launch()
		XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
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

	static func wait(_ element: XCUIElement, timeout: TimeInterval = 8) {
		XCTAssertTrue(element.waitForExistence(timeout: timeout), "missing \(element)")
	}

	static func waitUntilHittable(_ element: XCUIElement, timeout: TimeInterval = 8) {
		let hittable = XCTNSPredicateExpectation(
			predicate: NSPredicate(format: "hittable == true"), object: element)
		XCTAssertEqual(
			XCTWaiter.wait(for: [hittable], timeout: timeout), .completed, "not hittable \(element)"
		)
	}

	static func waitUntilEnabled(_ element: XCUIElement, timeout: TimeInterval = 8) {
		wait(element, timeout: timeout)
		let enabled = XCTNSPredicateExpectation(
			predicate: NSPredicate(format: "enabled == true"), object: element)
		XCTAssertEqual(
			XCTWaiter.wait(for: [enabled], timeout: timeout), .completed, "not enabled \(element)")
	}

	static func waitForAbsence(_ element: XCUIElement, timeout: TimeInterval = 8) {
		let gone = XCTNSPredicateExpectation(
			predicate: NSPredicate(format: "exists == false"), object: element)
		XCTAssertEqual(
			XCTWaiter.wait(for: [gone], timeout: timeout), .completed, "still on screen \(element)")
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

	static func waitForLabel(_ app: XCUIApplication, _ text: String, timeout: TimeInterval = 10) {
		let exact = app.staticTexts[text]
		if exact.waitForExistence(timeout: timeout) {
			return
		}
		let partial = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", text))
			.firstMatch
		XCTAssertTrue(partial.waitForExistence(timeout: 2), "missing text \(text)")
	}

	static func waitForWelcome(_ app: XCUIApplication, timeout: TimeInterval = 10) {
		let welcome = named(app, "chat.welcome")
		wait(welcome, timeout: timeout)
		XCTAssertTrue(welcome.label.hasPrefix(welcomeHead), "welcome reads \(welcome.label)")
	}

	static func startNewConversation(_ app: XCUIApplication) {
		let button = named(app, "chat.newConversation")
		waitUntilHittable(button)
		button.tap()
		waitForWelcome(app)
	}

	static func openHistory(_ app: XCUIApplication) {
		openSidebar(app)
		named(app, "sidebar.history").tap()
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
		_ app: XCUIApplication, _ text: String, timeout: TimeInterval = 30
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
		let expected = "turns \(count + 1) settled \(count + 1)"
		let settled = XCTNSPredicateExpectation(
			predicate: NSPredicate(format: "value == %@", expected), object: progress)
		XCTAssertEqual(
			XCTWaiter.wait(for: [settled], timeout: timeout), .completed,
			"\(text) never settled: expected \(expected), got \(progress.value as? String ?? "missing")"
		)
	}

	static func sendLong(_ app: XCUIApplication) {
		exchange(app, "fixture:long")
		wait(text(app, containing: "Day 100. This week has"))
	}

	static func openSidebar(_ app: XCUIApplication) {
		let sidebar = named(app, "chat.sidebar")
		waitUntilHittable(sidebar)
		sidebar.tap()
		wait(named(app, "sidebar.credits"))
	}

	static func openRecords(_ app: XCUIApplication) {
		openSidebar(app)
		named(app, "sidebar.debug").tap()
		let count = named(app, "fixture.requestCount")
		wait(count)
		XCTAssertEqual(count.label, "0 requests")
		named(app, "debug.records").tap()
		wait(named(app, "records.device"))
	}

	static func openCredentials(_ app: XCUIApplication) {
		openSidebar(app)
		named(app, "sidebar.debug").tap()
		let credentials = named(app, "debug.credentials")
		wait(credentials)
		credentials.tap()
		wait(named(app, "credentials.outcome"))
	}

	static func waitForIdentifier(
		_ app: XCUIApplication, _ identifier: String, reading label: String,
		timeout: TimeInterval = 8
	) {
		let element = app.descendants(matching: .any).matching(
			NSPredicate(format: "identifier == %@ AND label == %@", identifier, label)
		).firstMatch
		XCTAssertTrue(
			element.waitForExistence(timeout: timeout),
			"\(identifier) never read \(label); it reads \(named(app, identifier).label)")
	}

	static func closeMenu(_ app: XCUIApplication) {
		let sidebar = named(app, "chat.sidebar")
		for _ in 0..<3 {
			app.swipeDown(velocity: .fast)
			if becomesHittable(sidebar, within: 2) {
				break
			}
		}
		waitUntilHittable(sidebar)
		wait(named(app, "chat.composer"))
	}

	private static func becomesHittable(_ element: XCUIElement, within timeout: TimeInterval)
		-> Bool
	{
		let hittable = XCTNSPredicateExpectation(
			predicate: NSPredicate(format: "hittable == true"), object: element)
		return XCTWaiter.wait(for: [hittable], timeout: timeout) == .completed
	}

	static func historyHead(_ app: XCUIApplication) -> String {
		openSidebar(app)
		named(app, "sidebar.debug").tap()
		let head = named(app, "fixture.historyHead")
		wait(head)
		let label = head.label
		closeMenu(app)
		return label
	}

	static func assertZeroFixtureRequests(_ app: XCUIApplication) {
		openSidebar(app)
		named(app, "sidebar.debug").tap()
		let count = named(app, "fixture.requestCount")
		wait(count)
		XCTAssertEqual(count.label, "0 requests")
		closeMenu(app)
	}
}
