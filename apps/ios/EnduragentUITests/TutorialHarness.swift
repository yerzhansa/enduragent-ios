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
	static let responseFailure = "The coach couldn't respond. Please try again."
	static let storeArgument = "-EnduragentFixtureStore"

	static func launch(_ app: XCUIApplication, dark: Bool = false) {
		app.launchArguments = [
			"-EnduragentFixture", "first-week", storeArgument, "fresh",
			"-AppleLanguages", "(en)", "-AppleLocale", "en_US",
		]
		if dark {
			app.launchArguments += ["-AppleInterfaceStyle", "Dark"]
		}
		app.launch()
	}

	static func launchKeepingStore(_ app: XCUIApplication) throws {
		app.launchArguments = [
			"-EnduragentFixture", "first-week", storeArgument, "keep",
			"-AppleLanguages", "(en)", "-AppleLocale", "en_US",
		]
		app.launch()
		XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
		if app.staticTexts[notice].waitForExistence(timeout: 3) {
			throw XCTSkip(
				"needs a fixture store an earlier build wrote; run it after a trunk proof")
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

	static func wait(_ element: XCUIElement, timeout: TimeInterval = 8) {
		XCTAssertTrue(element.waitForExistence(timeout: timeout), "missing \(element)")
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
		named(app, "chat.sidebar").tap()
		wait(named(app, "sidebar.credits"))
	}

	static func openRecords(_ app: XCUIApplication) {
		openSidebar(app)
		named(app, "sidebar.debug").tap()
		wait(named(app, "fixture.requestCount"))
		named(app, "debug.records").tap()
		wait(named(app, "records.device"))
	}

	static func closeMenu(_ app: XCUIApplication) {
		app.swipeDown(velocity: .fast)
		app.swipeDown(velocity: .fast)
		wait(named(app, "chat.composer"))
	}

	static func recordCount(_ app: XCUIApplication, _ kind: String) -> String? {
		let element = named(app, "records.count.\(kind)")
		return element.exists ? element.label : nil
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
		app.swipeDown(velocity: .fast)
		app.swipeDown(velocity: .fast)
	}
}
