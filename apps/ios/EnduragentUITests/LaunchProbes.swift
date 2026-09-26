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

	func testLaunchRecoveringOneDeadClaim() {
		let app = keptApp()
		app.launch()
		TutorialHarness.wait(app.staticTexts[Self.lastSeed], timeout: 60)
		TutorialHarness.send(app, "fixture:hang")
		TutorialHarness.openRecords(app)
		TutorialHarness.waitForRecordCount(app, "turnClaim", "turnClaim \(Self.seeds + 1)")
		app.terminate()
		let started = Date()
		app.launch()
		let notice = TutorialHarness.notice(app, reading: TutorialHarness.interruptedNothingChanged)
		while !notice.exists, Date().timeIntervalSince(started) < 60 {
			continue
		}
		record(Date().timeIntervalSince(started), name: "recovery-launch-latency-ms")
		XCTAssertTrue(notice.exists)
		TutorialHarness.attach(self, name: "launch-recovering-one-dead-claim", app: app)
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
