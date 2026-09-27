import XCTest

final class FlushSurvivesKillProof: XCTestCase {
	func testFlushSurvivesKill() {
		let app = XCUIApplication()
		TutorialHarness.launch(app)
		TutorialHarness.completeOnboarding(app)
		TutorialHarness.exchange(app, "fixture:flush-partial")
		TutorialHarness.exchange(app, "fixture:fail overflow")
		TutorialHarness.openRecords(app)
		TutorialHarness.waitForRecordCount(app, "ledgerEvent", "ledgerEvent 1")
		XCTAssertEqual(TutorialHarness.recordCount(app, "flushPending"), "flushPending 1")
		XCTAssertEqual(TutorialHarness.recordCount(app, "memorySection"), "memorySection 1")
		XCTAssertNil(TutorialHarness.recordCount(app, "flushSettled"))
		TutorialHarness.attach(self, name: "flush-pending-before-kill", app: app)
		TutorialHarness.relaunchKeepingStore(app)
		TutorialHarness.wait(TutorialHarness.named(app, "chat.composer"))
		TutorialHarness.openRecords(app)
		TutorialHarness.waitForRecordCount(app, "flushSettled", "flushSettled 1")
		XCTAssertEqual(TutorialHarness.recordCount(app, "flushPending"), "flushPending 1")
		XCTAssertEqual(TutorialHarness.recordCount(app, "ledgerEvent"), "ledgerEvent 1")
		TutorialHarness.attach(self, name: "flush-settled-after-relaunch", app: app)
		TutorialHarness.closeMenu(app)
		TutorialHarness.assertZeroFixtureRequests(app)
	}
}

final class SummaryFirstProof: XCTestCase {
	func testSummaryFirst() {
		let app = XCUIApplication()
		TutorialHarness.launch(app)
		TutorialHarness.completeOnboarding(app)
		for _ in 1...6 {
			TutorialHarness.sendLong(app)
		}
		TutorialHarness.send(app, TutorialHarness.weekQuestion)
		TutorialHarness.waitForLabel(app, TutorialHarness.weekReply, timeout: 30)
		TutorialHarness.openRecords(app)
		TutorialHarness.waitForRecordCount(app, "compactionSummary", "compactionSummary 1")
		XCTAssertEqual(TutorialHarness.recordCount(app, "windowStart"), "windowStart 1")
		TutorialHarness.attach(self, name: "summary-records", app: app)
		TutorialHarness.closeMenu(app)
		XCTAssertEqual(TutorialHarness.historyHead(app), TutorialHarness.summaryHead)
		TutorialHarness.send(app, TutorialHarness.remember)
		TutorialHarness.waitForLabel(app, TutorialHarness.rememberReply, timeout: 30)
		XCTAssertEqual(TutorialHarness.historyHead(app), TutorialHarness.summaryHead)
		TutorialHarness.attach(self, name: "summary-first-next-turn", app: app)
		TutorialHarness.assertZeroFixtureRequests(app)
	}
}

final class SoftFlushGateProof: XCTestCase {
	func testSoftFlushWaitsForTheGate() {
		let app = XCUIApplication()
		TutorialHarness.launch(app)
		TutorialHarness.completeOnboarding(app)
		for _ in 1...4 {
			TutorialHarness.sendLong(app)
		}
		TutorialHarness.openRecords(app)
		TutorialHarness.waitForRecordCount(app, "turnSettled", "turnSettled 4")
		XCTAssertNil(TutorialHarness.recordCount(app, "flushPending"))
		TutorialHarness.attach(self, name: "soft-gate-holds", app: app)
		TutorialHarness.closeMenu(app)
		TutorialHarness.sendLong(app)
		TutorialHarness.exchange(app, TutorialHarness.weekQuestion)
		TutorialHarness.openRecords(app)
		TutorialHarness.waitForRecordCount(app, "flushSettled", "flushSettled 1")
		XCTAssertEqual(TutorialHarness.recordCount(app, "flushPending"), "flushPending 1")
		XCTAssertNil(TutorialHarness.recordCount(app, "windowStart"))
		TutorialHarness.attach(self, name: "soft-gate-opens", app: app)
		TutorialHarness.closeMenu(app)
		TutorialHarness.assertZeroFixtureRequests(app)
	}
}

final class DrainAtLaunchProof: XCTestCase {
	func testDrainAtLaunchBesideAnInterruptedTurn() {
		let app = XCUIApplication()
		TutorialHarness.launch(app)
		TutorialHarness.completeOnboarding(app)
		TutorialHarness.exchange(app, "fixture:flush-partial")
		TutorialHarness.exchange(app, "fixture:fail overflow")
		TutorialHarness.send(app, "fixture:hang")
		TutorialHarness.openRecords(app)
		TutorialHarness.waitForRecordCount(app, "turnClaim", "turnClaim 3")
		XCTAssertEqual(TutorialHarness.recordCount(app, "flushPending"), "flushPending 1")
		XCTAssertNil(TutorialHarness.recordCount(app, "flushSettled"))
		TutorialHarness.relaunchKeepingStore(app)
		let notice = TutorialHarness.notice(app, reading: TutorialHarness.interruptedNothingChanged)
		TutorialHarness.wait(notice)
		XCTAssertTrue(TutorialHarness.named(app, "chat.turn.tryAgain").exists)
		TutorialHarness.attach(self, name: "drain-at-launch-notice", app: app)
		TutorialHarness.openRecords(app)
		TutorialHarness.waitForRecordCount(app, "flushSettled", "flushSettled 1")
		XCTAssertEqual(TutorialHarness.recordCount(app, "flushPending"), "flushPending 1")
		XCTAssertEqual(TutorialHarness.recordCount(app, "ledgerEvent"), "ledgerEvent 1")
		TutorialHarness.attach(self, name: "drain-at-launch-records", app: app)
		TutorialHarness.closeMenu(app)
		TutorialHarness.assertZeroFixtureRequests(app)
		TutorialHarness.openRecords(app)
		let settled = TutorialHarness.settlementRows(app)
		XCTAssertEqual(settled.count, 3, "rows: \(settled)")
		XCTAssertTrue(
			settled.contains { $0.contains("interrupted processEnded") }, "rows: \(settled)")
	}
}
