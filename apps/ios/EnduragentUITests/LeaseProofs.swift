import XCTest

final class StopProof: XCTestCase {
	func testStop() {
		let app = XCUIApplication()
		TutorialHarness.launch(app)
		TutorialHarness.completeOnboarding(app)
		TutorialHarness.send(app, "fixture:slow")
		TutorialHarness.wait(TutorialHarness.text(app, containing: "This week has"), timeout: 10)
		let stop = TutorialHarness.named(app, "chat.stop")
		TutorialHarness.wait(stop)
		XCTAssertEqual(stop.label, "Stop responding")
		stop.tap()
		let notice = TutorialHarness.notice(app, reading: TutorialHarness.interruptedNothingChanged)
		TutorialHarness.wait(notice)
		XCTAssertTrue(TutorialHarness.named(app, "chat.turn.tryAgain").exists)
		XCTAssertTrue(TutorialHarness.text(app, containing: "This week has").exists)
		let message = app.staticTexts["fixture:slow"]
		XCTAssertGreaterThan(
			notice.frame.height, message.frame.height * 1.5,
			"the two-line notice is cut to one line: \(notice.frame) vs \(message.frame)")
		XCTAssertFalse(
			TutorialHarness.text(app, containing: "quieter stretch between them.").exists)
		XCTAssertFalse(TutorialHarness.named(app, "chat.stop").exists)
		XCTAssertFalse(TutorialHarness.named(app, "chat.working").exists)
		TutorialHarness.attach(self, name: "stop", app: app)
		TutorialHarness.openRecords(app)
		TutorialHarness.waitForRecordCount(app, "turnSettled", "turnSettled 1")
		let settled = TutorialHarness.settlementRows(app)
		XCTAssertTrue(settled.first?.contains("interrupted athleteStopped") == true, "\(settled)")
		TutorialHarness.attach(self, name: "stop-records", app: app)
		TutorialHarness.closeMenu(app)
		TutorialHarness.assertZeroFixtureRequests(app)
	}
}

final class ExpiryProof: XCTestCase {
	func testExpiry() {
		let app = XCUIApplication()
		TutorialHarness.launch(app, host: "expire-after 3")
		TutorialHarness.completeOnboarding(app)
		TutorialHarness.send(app, "fixture:slow")
		let sent = Date()
		let notice = TutorialHarness.notice(app, reading: TutorialHarness.interruptedNothingChanged)
		TutorialHarness.wait(notice, timeout: 15)
		let shown = Date().timeIntervalSince(sent)
		XCTAssertTrue(TutorialHarness.named(app, "chat.turn.tryAgain").exists)
		XCTAssertFalse(
			TutorialHarness.text(app, containing: "quieter stretch between them.").exists)
		TutorialHarness.attach(self, name: "expiry", app: app)
		let stamp = XCTAttachment(
			string: String(format: "send-to-interrupted-notice %.2f s", shown))
		stamp.name = "expiry-timing"
		stamp.lifetime = .keepAlways
		add(stamp)
		TutorialHarness.openRecords(app)
		TutorialHarness.waitForRecordCount(app, "turnSettled", "turnSettled 1")
		let rows = TutorialHarness.recordRowLabels(app)
		let settled = rows.filter { $0.hasPrefix("turnSettled") }
		XCTAssertTrue(settled.first?.contains("interrupted systemExpired") == true, "\(settled)")
		let claims = rows.filter { $0.hasPrefix("turnClaim") }
		XCTAssertTrue(claims.first?.contains("continuedProcessing") == true, "\(claims)")
		TutorialHarness.attach(self, name: "expiry-records", app: app)
		TutorialHarness.closeMenu(app)
		TutorialHarness.assertZeroFixtureRequests(app)
	}
}

final class FinishedWhileAwayProof: XCTestCase {
	func testFinishedWhileAway() {
		let app = XCUIApplication()
		TutorialHarness.launch(app)
		TutorialHarness.completeOnboarding(app)
		TutorialHarness.send(app, "fixture:slow")
		TutorialHarness.wait(TutorialHarness.named(app, "chat.working"), timeout: 2)
		XCUIDevice.shared.press(.home)
		Thread.sleep(forTimeInterval: 15)
		app.activate()
		XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
		let line = TutorialHarness.named(app, "chat.turn.finishedWhileLocked")
		TutorialHarness.wait(line)
		XCTAssertEqual(line.label, TutorialHarness.finishedWhileLocked)
		XCTAssertFalse(TutorialHarness.named(app, "chat.turn.notice").exists)
		TutorialHarness.attach(self, name: "finished-while-away", app: app)
		TutorialHarness.assertZeroFixtureRequests(app)
	}
}

final class QueuedExpiryProof: XCTestCase {
	func testQueuedExpiry() {
		let app = XCUIApplication()
		TutorialHarness.launch(app)
		TutorialHarness.completeOnboarding(app)
		TutorialHarness.send(app, "fixture:hang")
		TutorialHarness.openRecords(app)
		TutorialHarness.waitForRecordCount(app, "turnClaim", "turnClaim 1")
		TutorialHarness.closeMenu(app)
		TutorialHarness.send(app, TutorialHarness.weekQuestion)
		TutorialHarness.fixtureControl(app, "fixture.expire")
		let stopped = app.staticTexts.matching(
			NSPredicate(
				format: "identifier == %@ AND label == %@", "chat.turn.notice",
				TutorialHarness.interruptedNothingChanged))
		TutorialHarness.wait(stopped.element(boundBy: 1))
		XCTAssertEqual(stopped.count, 2)
		XCTAssertFalse(TutorialHarness.named(app, "chat.turn.receivedBeforeClose").exists)
		XCTAssertEqual(app.buttons.matching(identifier: "chat.turn.tryAgain").count, 2)
		XCTAssertEqual(app.staticTexts.matching(identifier: TutorialHarness.weekQuestion).count, 1)
		TutorialHarness.attach(self, name: "queued-expiry", app: app)
		TutorialHarness.assertZeroFixtureRequests(app)
	}
}

final class ExpiryAfterSaveProof: XCTestCase {
	func testExpiryAfterSave() {
		let app = XCUIApplication()
		TutorialHarness.launch(app)
		TutorialHarness.completeOnboarding(app)
		TutorialHarness.send(app, "fixture:memory-then-hang")
		TutorialHarness.openRecords(app)
		TutorialHarness.waitForRecordCount(app, "memorySection", "memorySection 1")
		TutorialHarness.closeMenu(app)
		TutorialHarness.fixtureControl(app, "fixture.expire")
		TutorialHarness.wait(
			TutorialHarness.notice(app, reading: TutorialHarness.interruptedSomeSaved))
		XCTAssertFalse(TutorialHarness.named(app, "chat.turn.tryAgain").exists)
		TutorialHarness.attach(self, name: "expiry-after-save", app: app)
		TutorialHarness.assertZeroFixtureRequests(app)
	}
}

final class LeaseReportProof: XCTestCase {
	func testLeaseReport() {
		let app = XCUIApplication()
		TutorialHarness.launch(app)
		TutorialHarness.completeOnboarding(app)
		TutorialHarness.exchange(app, TutorialHarness.weekQuestion)
		TutorialHarness.openSidebar(app)
		TutorialHarness.named(app, "sidebar.debug").tap()
		TutorialHarness.wait(TutorialHarness.named(app, "fixture.requestCount"))
		TutorialHarness.named(app, "debug.leases").tap()
		let row = TutorialHarness.named(app, "leases.row.0")
		TutorialHarness.wait(row)
		XCTAssertEqual(
			row.label,
			"athlete continuedProcessing settledTurns 1 of 1 step 1 of 10 finished with notice")
		XCTAssertFalse(TutorialHarness.named(app, "leases.row.1").exists)
		TutorialHarness.attach(self, name: "lease-report", app: app)
	}
}

final class StopTryAgainProof: XCTestCase {
	func testStopTryAgain() {
		let app = XCUIApplication()
		TutorialHarness.launch(app)
		TutorialHarness.completeOnboarding(app)
		TutorialHarness.send(app, "fixture:slow")
		TutorialHarness.wait(TutorialHarness.text(app, containing: "This week has"), timeout: 10)
		TutorialHarness.named(app, "chat.stop").tap()
		let tryAgain = TutorialHarness.named(app, "chat.turn.tryAgain")
		TutorialHarness.wait(tryAgain)
		tryAgain.tap()
		XCTAssertFalse(TutorialHarness.named(app, "chat.turn.notice").exists)
		XCTAssertEqual(
			app.staticTexts.containing(
				NSPredicate(format: "label CONTAINS %@", "quieter stretch between them.")
			).count, 1)
		TutorialHarness.attach(self, name: "retry-after-stop", app: app)
		TutorialHarness.openRecords(app)
		TutorialHarness.waitForRecordCount(app, "turnSettled", "turnSettled 2")
		XCTAssertEqual(TutorialHarness.recordCount(app, "userMessage"), "userMessage 1")
		XCTAssertEqual(TutorialHarness.recordCount(app, "turnClaim"), "turnClaim 2")
		let settled = TutorialHarness.settlementRows(app)
		XCTAssertTrue(settled.first?.contains("interrupted athleteStopped") == true, "\(settled)")
		XCTAssertTrue(settled.last?.contains("replied") == true, "\(settled)")
		TutorialHarness.attach(self, name: "retry-after-stop-records", app: app)
	}
}

final class LeaseTourProof: XCTestCase {
	func testLeaseTour() {
		let app = XCUIApplication()
		TutorialHarness.launch(app)
		TutorialHarness.completeOnboarding(app)
		TutorialHarness.send(app, "fixture:slow")
		TutorialHarness.wait(TutorialHarness.text(app, containing: "This week has"), timeout: 10)
		Thread.sleep(forTimeInterval: 1)
		TutorialHarness.named(app, "chat.stop").tap()
		TutorialHarness.wait(
			TutorialHarness.notice(app, reading: TutorialHarness.interruptedNothingChanged))
		Thread.sleep(forTimeInterval: 3)
		TutorialHarness.send(app, "fixture:hang")
		TutorialHarness.wait(TutorialHarness.named(app, "chat.working"), timeout: 5)
		Thread.sleep(forTimeInterval: 2)
		TutorialHarness.fixtureControl(app, "fixture.expire")
		let stopped = app.staticTexts.matching(
			NSPredicate(
				format: "identifier == %@ AND label == %@", "chat.turn.notice",
				TutorialHarness.interruptedNothingChanged))
		TutorialHarness.wait(stopped.element(boundBy: 1))
		Thread.sleep(forTimeInterval: 3)
		TutorialHarness.send(app, "fixture:slow")
		TutorialHarness.wait(TutorialHarness.named(app, "chat.working"), timeout: 5)
		XCUIDevice.shared.press(.home)
		Thread.sleep(forTimeInterval: 12)
		app.activate()
		XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
		TutorialHarness.wait(
			TutorialHarness.named(app, "chat.turn.finishedWhileLocked"), timeout: 20)
		Thread.sleep(forTimeInterval: 3)
		TutorialHarness.attach(self, name: "lease-tour", app: app)
	}
}
