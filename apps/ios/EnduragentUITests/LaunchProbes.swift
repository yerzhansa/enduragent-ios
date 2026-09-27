import XCTest

final class LaunchLatencyProbe: XCTestCase {
	static let seeds = 200
	static let lastSeed = "Seed \(seeds)"

	func testSeedTwoHundredTurns() {
		let app = XCUIApplication()
		TutorialHarness.launch(app, coalescingMilliseconds: 1)
		TutorialHarness.completeOnboarding(app)
		for index in 1...Self.seeds {
			TutorialHarness.send(app, "Seed \(index)")
			TutorialHarness.wait(app.staticTexts["Seed \(index)"], timeout: 30)
		}
		let working = TutorialHarness.named(app, "chat.working")
		let settled = XCTNSPredicateExpectation(
			predicate: NSPredicate(format: "exists == false"), object: working)
		XCTAssertEqual(XCTWaiter.wait(for: [settled], timeout: 600), .completed)
		TutorialHarness.openRecords(app)
		TutorialHarness.waitForRecordCount(app, "turnSettled", "turnSettled \(Self.seeds)")
		TutorialHarness.attach(self, name: "seeded-records", app: app)
	}

	func testLaunchWithTwoHundredTurns() {
		let app = keptApp()
		let started = Date()
		app.launch()
		let last = app.staticTexts[Self.lastSeed]
		while !last.exists, Date().timeIntervalSince(started) < 60 {
			continue
		}
		record(Date().timeIntervalSince(started), name: "launch-latency-ms")
		XCTAssertTrue(last.exists)
		TutorialHarness.attach(self, name: "launch-with-two-hundred-turns", app: app)
	}

	private func keptApp() -> XCUIApplication {
		let app = XCUIApplication()
		app.launchArguments = [
			"-EnduragentFixture", "first-week", TutorialHarness.storeArgument, "keep",
			"-AppleLanguages", "(en)", "-AppleLocale", "en_US",
		]
		return app
	}

	private func record(_ seconds: TimeInterval, name: String) {
		let sample = XCTAttachment(string: String(format: "%.0f", seconds * 1_000))
		sample.name = name
		sample.lifetime = .keepAlways
		add(sample)
	}
}

final class HistoryOpenProbe: XCTestCase {
	static let resets = 50

	func testSeedFiftyResets() {
		let app = XCUIApplication()
		TutorialHarness.launch(app, coalescingMilliseconds: 1)
		TutorialHarness.completeOnboarding(app)
		for index in 1...Self.resets {
			TutorialHarness.send(app, "Archived \(index)")
			TutorialHarness.wait(
				TutorialHarness.text(app, containing: TutorialHarness.weekReply), timeout: 30)
			TutorialHarness.startNewConversation(app)
		}
		TutorialHarness.openRecords(app)
		TutorialHarness.waitForRecordCount(app, "windowStart", "windowStart \(Self.resets)")
		TutorialHarness.attach(self, name: "seeded-resets", app: app)
	}

	func testHistoryOpenWithFiftyArchived() {
		let app = XCUIApplication()
		app.launchArguments = [
			"-EnduragentFixture", "first-week", TutorialHarness.storeArgument, "keep",
			"-AppleLanguages", "(en)", "-AppleLocale", "en_US",
		]
		app.launch()
		XCTAssertTrue(
			stampHistoryOpen(
				app, until: app.staticTexts["Archived \(Self.resets)"], name: "history-open-ms"))
		TutorialHarness.attach(self, name: "history-with-fifty-archived", app: app)
	}

	func testHistoryOpenWithNoneArchived() {
		let app = XCUIApplication()
		TutorialHarness.launch(app)
		TutorialHarness.completeOnboarding(app)
		XCTAssertTrue(
			stampHistoryOpen(
				app, until: TutorialHarness.text(app, containing: "No past conversations yet."),
				name: "history-open-empty-ms"))
	}

	private func stampHistoryOpen(_ app: XCUIApplication, until shown: XCUIElement, name: String)
		-> Bool
	{
		TutorialHarness.openSidebar(app)
		let started = Date()
		TutorialHarness.named(app, "sidebar.history").tap()
		while !shown.exists, Date().timeIntervalSince(started) < 30 {
			continue
		}
		let sample = XCTAttachment(
			string: String(format: "%.0f", Date().timeIntervalSince(started) * 1_000))
		sample.name = name
		sample.lifetime = .keepAlways
		add(sample)
		return shown.exists
	}
}
