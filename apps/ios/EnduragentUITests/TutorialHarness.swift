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
	static let tryAgain = "Try again"
	static let summaryHead = "[Previous conversation summary]"
	static let draft = "Is Thursday still on?"
	static let finishedWhileLocked = "Finished while the phone was locked."
	static let storeArgument = "-EnduragentFixtureStore"
	static let keychainArgument = "-EnduragentFixtureKeychain"
	static let coalescingArgument = "-EnduragentFixtureCoalescing"
	static let recoveryArgument = "-EnduragentFixtureRecovery"
	static let hostArgument = "-EnduragentFixtureHost"

	static func launch(
		_ app: XCUIApplication, dark: Bool = false, keychain: String? = nil,
		coalescingMilliseconds: Int? = nil, host: String? = nil, language: String = "en",
		locale: String = "en_US"
	) {
		app.launchArguments = [
			"-EnduragentFixture", "first-week", storeArgument, "fresh",
			"-AppleLanguages", "(\(language))", "-AppleLocale", locale,
		]
		if dark {
			app.launchArguments += ["-AppleInterfaceStyle", "Dark"]
		}
		if let keychain {
			app.launchArguments += [keychainArgument, keychain]
		}
		if let coalescingMilliseconds {
			app.launchArguments += [coalescingArgument, String(coalescingMilliseconds)]
		}
		if let host {
			app.launchArguments += [hostArgument, host]
		}
		app.launch()
	}

	static func launchKeepingStore(_ app: XCUIApplication, expecting element: XCUIElement) throws {
		app.launchArguments = [
			"-EnduragentFixture", "first-week", storeArgument, "keep",
			"-AppleLanguages", "(en)", "-AppleLocale", "en_US",
		]
		app.launch()
		XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
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

	static func relaunchKeepingStore(_ app: XCUIApplication, recovery: String = "readable") {
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

	static func waitForLabel(_ app: XCUIApplication, _ text: String, timeout: TimeInterval = 10) {
		let exact = app.staticTexts[text]
		if exact.waitForExistence(timeout: timeout) {
			return
		}
		let partial = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", text))
			.firstMatch
		XCTAssertTrue(partial.waitForExistence(timeout: 2), "missing text \(text)")
	}

	static func completeOnboarding(_ app: XCUIApplication) {
		waitForLabel(app, notice)
		named(app, "notice.continue").tap()
		let key = named(app, "connect.apiKey")
		wait(key)
		key.tap()
		key.typeText("fixture")
		named(app, "connect.connect").tap()
		wait(named(app, "connect.athleteName"))
		XCTAssertEqual(named(app, "connect.athleteName").label, "Ada Kovač")
		XCTAssertEqual(named(app, "connect.fitness").label, "Fitness 42")
		XCTAssertEqual(named(app, "connect.fatigue").label, "Fatigue 49")
		XCTAssertEqual(named(app, "connect.form").label, "Form -7")
		named(app, "connect.continue").tap()
		wait(named(app, "starter.credits"))
		XCTAssertEqual(named(app, "starter.credits").label, "200 credits")
		named(app, "starter.start").tap()
		wait(named(app, "chat.composer"))
		waitForWelcome(app)
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

	static func exchange(_ app: XCUIApplication, _ text: String, timeout: TimeInterval = 30) {
		send(app, text)
		let working = named(app, "chat.working")
		wait(working, timeout: 5)
		XCTAssertTrue(working.waitForNonExistence(timeout: timeout), "\(text) never finished")
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

	static func recordCount(_ app: XCUIApplication, _ kind: String) -> String? {
		let element = named(app, "records.count.\(kind)")
		return element.exists ? element.label : nil
	}

	static func waitForRecordCount(
		_ app: XCUIApplication, _ kind: String, _ expected: String, timeout: TimeInterval = 10
	) {
		let deadline = Date().addingTimeInterval(timeout)
		while recordCount(app, kind) != expected, Date() < deadline {
			app.buttons["Refresh"].tap()
		}
		XCTAssertEqual(recordCount(app, kind), expected)
	}

	static func settlementRows(_ app: XCUIApplication) -> [String] {
		recordRowLabels(app).filter { $0.hasPrefix("turnSettled") }
	}

	static func recordRowLabels(_ app: XCUIApplication) -> [String] {
		var seen: [String] = []
		var labels: [String] = []
		for _ in 0..<8 {
			let rows = app.descendants(matching: .any).matching(
				NSPredicate(format: "identifier BEGINSWITH %@", "records.row.")
			).allElementsBoundByIndex
			var added = false
			for row in rows where !seen.contains(row.identifier) {
				seen.append(row.identifier)
				labels.append(row.label)
				added = true
			}
			if !added, !labels.isEmpty {
				break
			}
			app.swipeUp()
		}
		return labels
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
