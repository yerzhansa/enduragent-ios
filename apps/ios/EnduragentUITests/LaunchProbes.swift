import XCTest

final class LaunchLatencyProbe: XCTestCase {
	static let seeds = 200
	static let lastSeed = "Seed \(seeds)"

	func testSeedTwoHundredTurns() {
		let app = XCUIApplication()
		TutorialHarness.launch(app, coalescingMilliseconds: 1)
		TutorialHarness.completeOnboarding(app)
		for index in 1...Self.seeds {
			TutorialHarness.exchange(app, "Seed \(index)")
			TutorialHarness.wait(app.staticTexts["Seed \(index)"], within: .turn)
		}
		let working = TutorialHarness.named(app, "chat.working")
		TutorialHarness.wait(working, until: .absent, within: .bulk)
		TutorialHarness.openRecords(app)
		TutorialHarness.waitForRecordCount(app, "turnSettled", "turnSettled \(Self.seeds)")
		TutorialHarness.attach(self, name: "seeded-records", app: app)
	}

	func testLaunchWithTwoHundredTurns() {
		let app = XCUIApplication()
		let started = Date()
		TutorialHarness.launch(app, arguments: FixtureArguments(store: .keep))
		let last = app.staticTexts[Self.lastSeed]
		TutorialHarness.wait(last, within: .longTurn)
		record(Date().timeIntervalSince(started), name: "launch-latency-ms")
		XCTAssertTrue(last.exists)
		TutorialHarness.attach(self, name: "launch-with-two-hundred-turns", app: app)
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
			TutorialHarness.exchange(app, "Archived \(index)")
			TutorialHarness.wait(
				TutorialHarness.text(app, containing: TutorialHarness.weekReply), within: .turn)
			TutorialHarness.startNewConversation(app)
		}
		TutorialHarness.openRecords(app)
		TutorialHarness.waitForRecordCount(app, "windowStart", "windowStart \(Self.resets)")
		TutorialHarness.attach(self, name: "seeded-resets", app: app)
	}

	func testHistoryOpenWithFiftyArchived() {
		let app = XCUIApplication()
		TutorialHarness.launch(app, arguments: FixtureArguments(store: .keep))
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
		let history = TutorialHarness.named(app, "chat.history")
		TutorialHarness.wait(history, until: .hittable)
		let started = Date()
		history.tap()
		TutorialHarness.wait(shown, within: .turn)
		let sample = XCTAttachment(
			string: String(format: "%.0f", Date().timeIntervalSince(started) * 1_000))
		sample.name = name
		sample.lifetime = .keepAlways
		add(sample)
		return shown.exists
	}
}
