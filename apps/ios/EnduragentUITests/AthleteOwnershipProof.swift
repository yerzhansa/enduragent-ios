import EnduragentCoachFixtures
import XCTest

@MainActor
final class AthleteOwnershipProof: XCTestCase {
	func testOwnershipBeforeChangeAfterChangeAndRelaunch() {
		AthleteOwnershipScreen.prove(self)
	}
}

@MainActor
private enum AthleteOwnershipScreen {
	static let savedLine = "Saved for another intervals.icu athlete (i1001)"
	static let reviewNotice =
		"This workout was prepared for a different intervals.icu athlete. Ask me again to prepare it for the connected athlete."

	static func prove(_ test: XCTestCase) {
		let app = XCUIApplication()
		TutorialHarness.launch(app)
		TutorialHarness.completeOnboarding(app)
		TutorialHarness.openDebug(app)
		TutorialHarness.debugRow(app, "fixture.seedOwnership").tap()
		let seedResult = TutorialHarness.debugRow(app, "fixture.ownershipSeedResult")
		TutorialHarness.waitForProgress(app, to: "ownership seeding finishing") {
			seedResult.label != "waiting"
		}
		XCTAssertEqual(seedResult.label, "seeded")
		TutorialHarness.returnToChat(app)
		TutorialHarness.exchange(app, TutorialHarness.workout)
		ReviewRecoveryScreen.assertButtons(app, .approval, enabled: true)
		assertExcludedCopy(in: TutorialHarness.named(app, "chat.transcript"))
		capture(test, app, stage: "before-change-conversation-review")
		assertHistory(test, app, changed: false, stage: "before-change")
		TutorialHarness.fixtureControl(app, "fixture.switchAthlete")
		TutorialHarness.exchange(app, "Read the connected athlete's week")
		assertBlockedReview(app)
		capture(test, app, stage: "after-change-conversation-review")
		assertHistory(test, app, changed: true, stage: "after-change")
		TutorialHarness.relaunchKeepingStore(app)
		assertBlockedReview(app)
		capture(test, app, stage: "relaunched-conversation-review")
		assertHistory(test, app, changed: true, stage: "relaunched")
	}

	private static func assertBlockedReview(_ app: XCUIApplication) {
		let transcript = TutorialHarness.named(app, "chat.transcript")
		let notice = transcript.staticTexts.matching(identifier: "chat.preview.notice").firstMatch
		TutorialHarness.scroll(app, to: notice)
		XCTAssertEqual(notice.label, reviewNotice)
		XCTAssertEqual(transcript.staticTexts.matching(identifier: "chat.preview.notice").count, 1)
		ReviewRecoveryScreen.assertButtons(transcript, .none, enabled: true)
		assertExcludedCopy(in: transcript)
		XCTAssertFalse(
			transcript.staticTexts.containing(
				NSPredicate(format: "identifier BEGINSWITH %@", "history.athlete.")
			).firstMatch.exists)
	}

	private static func assertHistory(
		_ test: XCTestCase, _ app: XCUIApplication, changed: Bool, stage: String
	) {
		TutorialHarness.openHistory(app)
		let history = TutorialHarness.named(app, "history.content")
		TutorialHarness.wait(history)
		let saved = history.descendants(matching: .any).matching(
			identifier: "history.row.\(AthleteOwnershipFixture.savedChat.rawValue)"
		).firstMatch
		let unknown = history.descendants(matching: .any).matching(
			identifier: "history.row.\(AthleteOwnershipFixture.unknownChat.rawValue)"
		).firstMatch
		TutorialHarness.wait(saved)
		TutorialHarness.wait(unknown)
		let label = saved.staticTexts.matching(
			identifier: "history.athlete.\(AthleteOwnershipFixture.savedChat.rawValue)")
		if changed {
			TutorialHarness.wait(label.firstMatch)
			XCTAssertEqual(label.count, 1)
			XCTAssertEqual(label.firstMatch.label, savedLine)
			XCTAssertFalse(saved.label.contains("Bo Lind"))
		} else {
			XCTAssertFalse(label.firstMatch.exists)
		}
		XCTAssertFalse(
			unknown.staticTexts.containing(
				NSPredicate(format: "identifier BEGINSWITH %@", "history.athlete.")
			).firstMatch.exists)
		assertExcludedCopy(in: history)
		capture(test, app, stage: "\(stage)-history")
		unknown.tap()
		let archive = TutorialHarness.named(app, "archive.content")
		TutorialHarness.wait(archive)
		XCTAssertTrue(archive.staticTexts[AthleteOwnershipFixture.unknownQuestion].exists)
		assertExcludedCopy(in: archive)
		XCTAssertFalse(
			archive.staticTexts.containing(
				NSPredicate(format: "label CONTAINS %@", "Saved for another")
			).firstMatch.exists)
		capture(test, app, stage: "\(stage)-unverified-archive")
		TutorialHarness.returnToChat(app)
	}

	private static func assertExcludedCopy(in container: XCUIElement) {
		for fragment in [
			"Athlete changed", "Connected athlete changed", "Unverified athlete",
			"Owner unverified",
		] {
			XCTAssertFalse(
				container.staticTexts.containing(
					NSPredicate(format: "label CONTAINS[c] %@", fragment)
				).firstMatch.exists)
		}
	}

	private static func capture(_ test: XCTestCase, _ app: XCUIApplication, stage: String) {
		TutorialHarness.attach(test, name: "u5-3-\(stage)-light", app: app)
		let luminance = TutorialHarness.meanLuminance(app.screenshot())
		XCTAssertGreaterThan(luminance, 0.4)
	}
}
