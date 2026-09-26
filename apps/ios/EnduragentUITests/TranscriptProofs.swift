import XCTest

final class LongRepliesProof: XCTestCase {
	func testLongReplies() {
		let app = XCUIApplication()
		TutorialHarness.launch(app)
		TutorialHarness.completeOnboarding(app)
		let replies = app.staticTexts.containing(
			NSPredicate(format: "label CONTAINS %@", "Day 100. This week has"))
		let working = TutorialHarness.named(app, "chat.working")
		for count in 1...3 {
			TutorialHarness.send(app, "fixture:long")
			let answered = XCTNSPredicateExpectation(
				predicate: NSPredicate(format: "count == %d", count), object: replies)
			XCTAssertEqual(XCTWaiter.wait(for: [answered], timeout: 30), .completed)
			XCTAssertTrue(working.waitForNonExistence(timeout: 30), "reply \(count) stays working")
		}
		TutorialHarness.send(app, TutorialHarness.weekQuestion)
		TutorialHarness.waitForLabel(app, TutorialHarness.weekReply)
		XCTAssertTrue(working.waitForNonExistence(timeout: 30))
		TutorialHarness.attach(self, name: "long-replies", app: app)
		TutorialHarness.assertZeroFixtureRequests(app)
	}
}
