import EnduragentCoach
import XCTest

@MainActor
final class StepLimitFallbackProof: XCTestCase {
	func testChosenLanguageInChatAfterRelaunchAndInHistory() {
		StepLimitFallbackScreen.prove(self)
	}
}

@MainActor
final class StepLimitFallbackDarkProof: XCTestCase {
	func testChosenLanguageInChatAfterRelaunchAndInHistory() {
		StepLimitFallbackScreen.prove(self)
	}
}

@MainActor
private enum StepLimitFallbackScreen {
	static let sentence =
		"J’ai atteint ma limite d’étapes en recueillant les données — demande-moi de continuer et je reprendrai là où je me suis arrêté."

	static func prove(_ test: XCTestCase) {
		let app = XCUIApplication()
		TutorialHarness.launch(app)
		TutorialHarness.completeOnboarding(app)
		TutorialHarness.send(app, "/language")
		let french = TutorialHarness.named(app, "language.choice.fr")
		TutorialHarness.wait(french, until: .hittable)
		french.tap()
		TutorialHarness.wait(app.navigationBars["Choisis ta langue"])
		TutorialHarness.named(app, "language.close").tap()
		TutorialHarness.exchange(app, "fixture:memory-then-step-limit")
		assertReply(app)
		TutorialHarness.attach(test, name: "step-limit-french", app: app)
		assertRecords(app, modelRequests: 11)
		TutorialHarness.relaunchKeepingStore(app)
		assertReply(app)
		assertRecords(app, modelRequests: 0)
		TutorialHarness.attach(test, name: "step-limit-french-restored", app: app)
		let newConversation = TutorialHarness.named(app, "chat.newConversation")
		TutorialHarness.wait(newConversation, until: .hittable)
		newConversation.tap()
		TutorialHarness.wait(TutorialHarness.named(app, "chat.welcome"))
		TutorialHarness.openHistory(app)
		let row = TutorialHarness.historyRows(app).firstMatch
		TutorialHarness.wait(row, until: .hittable)
		row.tap()
		TutorialHarness.wait(TutorialHarness.named(app, "archive.readOnly"))
		assertReply(app)
		TutorialHarness.attach(test, name: "step-limit-french-history", app: app)
	}

	private static func assertReply(_ app: XCUIApplication) {
		TutorialHarness.waitForIdentifier(app, "reply.paragraph", reading: sentence)
		XCTAssertFalse(TutorialHarness.named(app, "chat.turn.tryAgain").exists)
		XCTAssertFalse(TutorialHarness.text(app, containing: "I ran out of steps").exists)
	}

	private static func assertRecords(_ app: XCUIApplication, modelRequests: Int) {
		TutorialHarness.openDebug(app)
		XCTAssertEqual(
			TutorialHarness.debugRow(app, "fixture.modelRequestCount").label,
			"\(modelRequests) model requests")
		TutorialHarness.debugRow(app, "debug.records", direction: .down).tap()
		TutorialHarness.waitForRecordCount(app, "memorySection", "memorySection 1")
		TutorialHarness.waitForRecordCount(app, "turnSettled", "turnSettled 1")
		TutorialHarness.returnToChat(app)
	}
}
