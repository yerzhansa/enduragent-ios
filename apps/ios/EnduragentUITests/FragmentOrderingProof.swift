import XCTest

@MainActor
final class FragmentOrderingProof: XCTestCase {
	func testBufferedTextClosesBeforeLanguagePicker() {
		let app = XCUIApplication()
		TutorialHarness.launch(app, coalescingMilliseconds: 60_000)
		TutorialHarness.completeOnboarding(app)
		TutorialHarness.send(app, "Thursday?")
		TutorialHarness.send(app, "Friday?")
		let joined = app.staticTexts.matching(
			NSPredicate(format: "label == %@", "Thursday?\nFriday?"))
		TutorialHarness.wait(joined.firstMatch)
		XCTAssertEqual(joined.count, 1)
		XCTAssertTrue(TutorialHarness.named(app, "chat.working").exists)
		TutorialHarness.attach(self, name: "fragment-ordering-buffered", app: app)
		TutorialHarness.send(app, "/language")
		let close = TutorialHarness.named(app, "language.close")
		TutorialHarness.wait(close, until: .hittable)
		XCTAssertTrue(TutorialHarness.named(app, "language.choice.automatic").exists)
		TutorialHarness.attach(self, name: "fragment-ordering-picker", app: app)
		close.tap()
		TutorialHarness.wait(close, until: .absent)
		TutorialHarness.wait(
			TutorialHarness.named(app, "chat.turnProgress"),
			until: .value("turns 1 settled 1"), within: .turn)
		TutorialHarness.waitForLabel(app, TutorialHarness.weekReply)
		XCTAssertEqual(joined.count, 1)
		XCTAssertFalse(app.staticTexts["/language"].exists)
		XCTAssertFalse(TutorialHarness.named(app, "chat.working").exists)
		XCTAssertEqual(TutorialHarness.named(app, "chat.composer").value as? String, "")
		let reply = TutorialHarness.text(app, containing: TutorialHarness.weekReply)
		XCTAssertGreaterThan(reply.frame.minY, joined.firstMatch.frame.maxY)
		TutorialHarness.attach(self, name: "fragment-ordering-reply", app: app)
		TutorialHarness.openRecords(app)
		XCTAssertEqual(TutorialHarness.recordCount(app, "userMessage"), "userMessage 2")
		XCTAssertEqual(TutorialHarness.recordCount(app, "turnClaim"), "turnClaim 1")
		XCTAssertEqual(TutorialHarness.recordCount(app, "turnSettled"), "turnSettled 1")
		TutorialHarness.attach(self, name: "fragment-ordering-records", app: app)
		TutorialHarness.returnToChat(app)
	}
}
