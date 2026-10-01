import XCTest

final class SlowReplyProof: XCTestCase {
	func testSlowReply() {
		let app = XCUIApplication()
		TutorialHarness.launch(app)
		TutorialHarness.completeOnboarding(app)
		TutorialHarness.send(app, "fixture:slow")
		let working = TutorialHarness.named(app, "chat.working")
		TutorialHarness.wait(working, within: .screen)
		XCTAssertEqual(working.label, TutorialHarness.working)
		TutorialHarness.attach(self, name: "slow-reply-working", app: app)
		TutorialHarness.waitForLabel(app, "This week has", within: .screen)
		XCTAssertFalse(app.staticTexts["quieter stretch between them."].exists)
		XCTAssertTrue(working.exists, "the working row stays under the streaming text")
		TutorialHarness.attach(self, name: "slow-reply-streaming", app: app)
		TutorialHarness.waitForLabel(app, "quieter stretch between them.", within: .turn)
		TutorialHarness.wait(working, until: .absent, within: .turn)
		XCTAssertFalse(working.exists)
		TutorialHarness.attach(self, name: "slow-reply-done", app: app)
		TutorialHarness.assertZeroFixtureRequests(app)
	}
}

final class FailedReplyProof: XCTestCase {
	func testFailedReply() {
		let app = XCUIApplication()
		TutorialHarness.launch(app)
		TutorialHarness.completeOnboarding(app)
		TutorialHarness.exchange(app, "fixture:fail 500 x3")
		let notice = TutorialHarness.named(app, "chat.turn.notice")
		TutorialHarness.wait(notice)
		XCTAssertEqual(notice.label, TutorialHarness.providerDown)
		XCTAssertTrue(TutorialHarness.named(app, "chat.turn.tryAgain").exists)
		assertNoWireDetail(app)
		TutorialHarness.attach(self, name: "failed-reply", app: app)
		TutorialHarness.assertZeroFixtureRequests(app)
	}
}

final class AcceptSurvivesKillProof: XCTestCase {
	func testAcceptSurvivesKill() {
		let app = XCUIApplication()
		TutorialHarness.launch(app, coalescingMilliseconds: 60_000)
		TutorialHarness.completeOnboarding(app)
		TutorialHarness.send(app, "fixture:hang")
		TutorialHarness.wait(TutorialHarness.named(app, "chat.working"), within: .screen)
		TutorialHarness.attach(self, name: "accept-kill-received", app: app)
		TutorialHarness.openRecords(app)
		TutorialHarness.waitForRecordCount(app, "userMessage", "userMessage 1")
		XCTAssertNil(TutorialHarness.recordCount(app, "turnClaim"))
		TutorialHarness.relaunchKeepingStore(app)
		TutorialHarness.wait(TutorialHarness.named(app, "chat.composer"))
		TutorialHarness.waitForLabel(app, TutorialHarness.receivedBeforeClose)
		XCTAssertEqual(app.staticTexts.matching(identifier: "fixture:hang").count, 1)
		let tryAgain = TutorialHarness.named(app, "chat.turn.tryAgain")
		TutorialHarness.wait(tryAgain)
		XCTAssertFalse(TutorialHarness.named(app, "chat.working").exists)
		TutorialHarness.attach(self, name: "accept-kill-reopen", app: app)
		TutorialHarness.openRecords(app)
		XCTAssertEqual(TutorialHarness.recordCount(app, "userMessage"), "userMessage 1")
		XCTAssertNil(TutorialHarness.recordCount(app, "turnClaim"))
		XCTAssertNil(TutorialHarness.recordCount(app, "turnSettled"))
		TutorialHarness.attach(self, name: "accept-kill-records", app: app)
		TutorialHarness.closeMenu(app)
		tryAgain.tap()
		TutorialHarness.waitForLabel(app, TutorialHarness.weekReply)
		TutorialHarness.wait(
			TutorialHarness.named(app, "chat.working"), until: .absent, within: .turn)
		XCTAssertEqual(app.staticTexts.matching(identifier: "fixture:hang").count, 1)
		XCTAssertFalse(tryAgain.exists)
		TutorialHarness.attach(self, name: "accept-kill-try-again", app: app)
		TutorialHarness.openRecords(app)
		XCTAssertEqual(TutorialHarness.recordCount(app, "userMessage"), "userMessage 1")
		XCTAssertEqual(TutorialHarness.recordCount(app, "turnClaim"), "turnClaim 1")
		XCTAssertEqual(TutorialHarness.recordCount(app, "turnSettled"), "turnSettled 1")
		TutorialHarness.attach(self, name: "accept-kill-try-again-records", app: app)
		TutorialHarness.closeMenu(app)
		TutorialHarness.assertZeroFixtureRequests(app)
	}
}

final class HangWatchdogProof: XCTestCase {
	func testHangWatchdog() {
		let app = XCUIApplication()
		TutorialHarness.launch(app)
		TutorialHarness.completeOnboarding(app)
		TutorialHarness.send(app, "fixture:hang")
		let working = TutorialHarness.named(app, "chat.working")
		TutorialHarness.wait(working, within: .screen)
		TutorialHarness.attach(self, name: "hang-working", app: app)
		let notice = TutorialHarness.named(app, "chat.turn.notice")
		TutorialHarness.wait(notice, within: .watchdog)
		XCTAssertEqual(notice.label, TutorialHarness.providerDown)
		XCTAssertTrue(TutorialHarness.named(app, "chat.turn.tryAgain").exists)
		XCTAssertFalse(working.exists)
		TutorialHarness.attach(self, name: "hang-watchdog", app: app)
		TutorialHarness.openRecords(app)
		TutorialHarness.waitForRecordCount(app, "turnSettled", "turnSettled 1")
		TutorialHarness.attach(self, name: "hang-watchdog-records", app: app)
		TutorialHarness.closeMenu(app)
	}
}

final class StorageFaultProof: XCTestCase {
	func testStorageFault() {
		let app = XCUIApplication()
		TutorialHarness.launch(app)
		TutorialHarness.completeOnboarding(app)
		TutorialHarness.fixtureControl(app, "fixture.failNextAppend")
		TutorialHarness.send(app, TutorialHarness.weekQuestion)
		let notSent = TutorialHarness.named(app, "chat.composer.notSent")
		TutorialHarness.wait(notSent)
		XCTAssertEqual(notSent.label, TutorialHarness.notSent)
		XCTAssertEqual(
			TutorialHarness.named(app, "chat.composer").value as? String,
			TutorialHarness.weekQuestion)
		XCTAssertFalse(app.staticTexts[TutorialHarness.weekQuestion].exists)
		XCTAssertFalse(TutorialHarness.named(app, "chat.working").exists)
		TutorialHarness.attach(self, name: "storage-fault-not-sent", app: app)
		TutorialHarness.assertZeroFixtureRequests(app)
		TutorialHarness.relaunchKeepingStore(app)
		TutorialHarness.wait(TutorialHarness.named(app, "chat.composer"))
		TutorialHarness.waitForWelcome(app)
		XCTAssertEqual(
			TutorialHarness.named(app, "chat.composer").value as? String,
			TutorialHarness.weekQuestion)
		XCTAssertFalse(app.staticTexts[TutorialHarness.weekQuestion].exists)
		TutorialHarness.attach(self, name: "storage-fault-nothing-saved", app: app)
		TutorialHarness.openRecords(app)
		XCTAssertNil(TutorialHarness.recordCount(app, "userMessage"))
		XCTAssertNil(TutorialHarness.recordCount(app, "turnSettled"))
		TutorialHarness.attach(self, name: "storage-fault-records", app: app)
	}
}

final class ReceivedBeforeReplyProof: XCTestCase {
	func testReceivedBeforeReply() {
		let app = XCUIApplication()
		TutorialHarness.launch(app, coalescingMilliseconds: 5_000)
		TutorialHarness.completeOnboarding(app)
		TutorialHarness.send(app, TutorialHarness.weekQuestion)
		TutorialHarness.wait(app.staticTexts[TutorialHarness.weekQuestion], within: .screen)
		XCTAssertTrue(TutorialHarness.named(app, "chat.working").exists)
		let reply = app.staticTexts.containing(
			NSPredicate(format: "label CONTAINS %@", TutorialHarness.weekReply))
		XCTAssertFalse(reply.firstMatch.exists)
		TutorialHarness.attach(self, name: "received", app: app)
		TutorialHarness.waitForLabel(app, TutorialHarness.weekReply)
		TutorialHarness.assertZeroFixtureRequests(app)
	}
}

final class DraftSurvivesKillProof: XCTestCase {
	func testDraftSurvivesKill() {
		let app = XCUIApplication()
		TutorialHarness.launch(app)
		TutorialHarness.completeOnboarding(app)
		let composer = TutorialHarness.named(app, "chat.composer")
		composer.tap()
		composer.typeText(TutorialHarness.draft)
		TutorialHarness.relaunchKeepingStore(app)
		TutorialHarness.wait(composer)
		TutorialHarness.waitForWelcome(app)
		XCTAssertEqual(composer.value as? String, TutorialHarness.draft)
		XCTAssertFalse(app.staticTexts[TutorialHarness.draft].exists)
		TutorialHarness.attach(self, name: "draft-survives", app: app)
		TutorialHarness.openRecords(app)
		XCTAssertNil(TutorialHarness.recordCount(app, "userMessage"))
		TutorialHarness.closeMenu(app)
	}
}

final class CoalesceProof: XCTestCase {
	func testCoalesce() {
		let app = XCUIApplication()
		TutorialHarness.launch(app, coalescingMilliseconds: 10_000)
		TutorialHarness.completeOnboarding(app)
		TutorialHarness.send(app, "Thursday?")
		TutorialHarness.send(app, "Friday?")
		let reply = app.staticTexts.containing(
			NSPredicate(format: "label CONTAINS %@", TutorialHarness.weekReply))
		TutorialHarness.wait(reply.firstMatch, within: .turn)
		TutorialHarness.wait(
			TutorialHarness.named(app, "chat.working"), until: .absent, within: .turn)
		let joined = app.staticTexts.matching(
			NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", "Thursday?", "Friday?"))
		XCTAssertEqual(joined.count, 1)
		TutorialHarness.attach(self, name: "coalesce", app: app)
		TutorialHarness.openRecords(app)
		XCTAssertEqual(TutorialHarness.recordCount(app, "userMessage"), "userMessage 2")
		XCTAssertEqual(TutorialHarness.recordCount(app, "turnClaim"), "turnClaim 1")
		XCTAssertEqual(TutorialHarness.recordCount(app, "turnSettled"), "turnSettled 1")
		TutorialHarness.attach(self, name: "coalesce-records", app: app)
		TutorialHarness.closeMenu(app)
		TutorialHarness.assertZeroFixtureRequests(app)
	}
}

final class SendLatencyProbe: XCTestCase {
	func testSendLatency() {
		let app = XCUIApplication()
		TutorialHarness.launch(app)
		TutorialHarness.completeOnboarding(app)
		let composer = TutorialHarness.named(app, "chat.composer")
		composer.tap()
		composer.typeText(TutorialHarness.weekQuestion)
		let send = TutorialHarness.named(app, "chat.send")
		TutorialHarness.wait(send)
		let bubble = app.staticTexts[TutorialHarness.weekQuestion]
		let tapped = Date()
		send.tap()
		TutorialHarness.wait(bubble, within: .screen)
		let latency = Date().timeIntervalSince(tapped)
		XCTAssertTrue(bubble.exists)
		let sample = XCTAttachment(string: String(format: "%.0f", latency * 1_000))
		sample.name = "send-latency-ms"
		sample.lifetime = .keepAlways
		add(sample)
		TutorialHarness.waitForLabel(app, TutorialHarness.weekReply)
		TutorialHarness.assertZeroFixtureRequests(app)
	}
}
