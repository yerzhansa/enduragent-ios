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
		TutorialHarness.exchange(app, TutorialHarness.weekQuestion)
		TutorialHarness.exchange(app, "fixture:fail overflow")
		TutorialHarness.openRecords(app)
		TutorialHarness.waitForRecordCount(app, "compactionSummary", "compactionSummary 1")
		XCTAssertEqual(TutorialHarness.recordCount(app, "windowStart"), "windowStart 1")
		TutorialHarness.attach(self, name: "summary-records", app: app)
		TutorialHarness.closeMenu(app)
		XCTAssertEqual(TutorialHarness.historyHead(app), TutorialHarness.summaryHead)
		TutorialHarness.exchange(app, TutorialHarness.remember)
		TutorialHarness.waitForLabel(app, TutorialHarness.rememberReply)
		XCTAssertEqual(TutorialHarness.historyHead(app), TutorialHarness.summaryHead)
		TutorialHarness.attach(self, name: "summary-first-next-turn", app: app)
		TutorialHarness.assertZeroFixtureRequests(app)
	}
}
