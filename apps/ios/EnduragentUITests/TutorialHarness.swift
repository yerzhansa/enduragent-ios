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
	static let greeting = "Hello, Ada."
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
	static let unknownFailure = "Sorry, something went wrong. Please try again."
	static let interruptedSomeSaved =
		"This reply stopped before it finished. Some information was saved first."
	static let interruptedNothingChanged =
		"This reply stopped before it finished. Nothing was changed."
	static let receivedBeforeClose = "Received before the app closed. Tap Try again to send it."
	static let notSent = "Not sent. Your draft is still here."
	static let tryAgain = "Try again"
	static let draft = "Is Thursday still on?"
	static let storeArgument = "-EnduragentFixtureStore"
	static let keychainArgument = "-EnduragentFixtureKeychain"
	static let coalescingArgument = "-EnduragentFixtureCoalescing"

	static func launch(
		_ app: XCUIApplication, dark: Bool = false, keychain: String? = nil,
		coalescingMilliseconds: Int? = nil
	) {
		app.launchArguments = [
			"-EnduragentFixture", "first-week", storeArgument, "fresh",
			"-AppleLanguages", "(en)", "-AppleLocale", "en_US",
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
		app.launch()
	}

	static func launchKeepingStore(_ app: XCUIApplication, expecting element: XCUIElement) throws {
		app.launchArguments = [
			"-EnduragentFixture", "first-week", storeArgument, "keep",
			"-AppleLanguages", "(en)", "-AppleLocale", "en_US",
		]
		app.launch()
		XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
		if !element.waitForExistence(timeout: 10) {
			throw XCTSkip(
				"needs the fixture store an earlier build left; run it after a trunk proof")
		}
	}

	static func relaunchKeepingStore(_ app: XCUIApplication) {
		app.terminate()
		XCTAssertEqual(app.state, .notRunning)
		guard let index = app.launchArguments.firstIndex(of: storeArgument),
			app.launchArguments.indices.contains(index + 1)
		else {
			XCTFail("launch arguments carry no \(storeArgument)")
			return
		}
		app.launchArguments[index + 1] = "keep"
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
		waitForLabel(app, greeting)
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
		app.swipeDown(velocity: .fast)
		app.swipeDown(velocity: .fast)
		waitUntilHittable(named(app, "chat.sidebar"))
		wait(named(app, "chat.composer"))
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
			if !added {
				break
			}
			app.swipeUp()
		}
		return labels
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
