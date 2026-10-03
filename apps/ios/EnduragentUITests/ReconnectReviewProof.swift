import Foundation
import XCTest

@MainActor
final class ReconnectReviewProof: XCTestCase {
	private let freshReview =
		"This workout was prepared for a different intervals.icu athlete. Ask me again to prepare it for the connected athlete."

	func testPeerChangeRequiresFreshApproval() throws {
		let app = launch()
		TutorialHarness.exchange(app, TutorialHarness.workout)
		ReviewRecoveryScreen.assertButtons(transcript(app), .approval, enabled: true)
		TutorialHarness.fixtureControl(app, "fixture.switchAthlete")
		TutorialHarness.exchange(app, "Read the connected athlete's week")
		TutorialHarness.waitForIdentifier(app, "chat.preview.notice", reading: freshReview)
		ReviewRecoveryScreen.assertButtons(transcript(app), .none, enabled: true)
		let blocked = try receipt(app, key: "athleteB")
		XCTAssertEqual(blocked.athleteAWrites, 0)
		XCTAssertEqual(blocked.athleteBWrites, 0)
		TutorialHarness.attach(self, name: "U5-4-fresh-review-required", app: app)
		TutorialHarness.exchange(app, TutorialHarness.workout)
		ReviewRecoveryScreen.assertButtons(transcript(app), .approval, enabled: true)
		XCTAssertEqual(try receipt(app, key: "athleteB").athleteBWrites, 0)
		TutorialHarness.attach(self, name: "U5-4-B-own-approval", app: app)
		TutorialHarness.named(app, "chat.preview.add").tap()
		TutorialHarness.waitForLabel(app, TutorialHarness.done)
		let saved = try receipt(app, key: "athleteB")
		XCTAssertEqual(saved.athleteAWrites, 0)
		XCTAssertEqual(saved.athleteBWrites, 1)
		TutorialHarness.attach(self, name: "U5-4-B-own-workout-saved", app: app)
		TutorialHarness.assertZeroFixtureRequests(app)
	}

	func testRotatedAReopensAndRecoversWithoutAnotherSave() throws {
		let app = launch(unknownSave: true)
		TutorialHarness.exchange(app, TutorialHarness.workout)
		ReviewRecoveryScreen.assertButtons(transcript(app), .approval, enabled: true)
		TutorialHarness.fixtureControl(app, "fixture.peerRotateA")
		TutorialHarness.relaunchKeepingStore(app)
		ReviewRecoveryScreen.assertButtons(transcript(app), .approval, enabled: true)
		let restored = try receipt(app, key: "rotatedA")
		XCTAssertGreaterThan(restored.athleteAProfileReads, 0)
		XCTAssertEqual(restored.athleteAWrites, 0)
		TutorialHarness.attach(self, name: "U5-4-rotated-A-restored-review", app: app)
		TutorialHarness.named(app, "chat.preview.add").tap()
		TutorialHarness.waitForIdentifier(
			app, "chat.preview.notice", reading: ReviewRecoveryScreen.pending)
		ReviewRecoveryScreen.assertButtons(transcript(app), .checkAgain, enabled: true)
		let unknown = try receipt(app, key: "rotatedA")
		XCTAssertEqual(unknown.athleteAWrites, 1)
		XCTAssertGreaterThan(unknown.athleteAProfileReads, restored.athleteAProfileReads)
		TutorialHarness.named(app, "chat.preview.checkAgain").tap()
		TutorialHarness.waitForLabel(app, TutorialHarness.done)
		ReviewRecoveryScreen.assertButtons(transcript(app), .none, enabled: true)
		let recovered = try receipt(app, key: "rotatedA")
		XCTAssertEqual(recovered.athleteAWrites, 1)
		XCTAssertEqual(recovered.athleteBWrites, 0)
		XCTAssertEqual(recovered.athleteACalendarCalls, unknown.athleteACalendarCalls + 1)
		XCTAssertEqual(recovered.athleteBCalendarCalls, 0)
		TutorialHarness.attach(self, name: "U5-4-rotated-A-read-back", app: app)
		TutorialHarness.assertZeroFixtureRequests(app)
	}

	func testCancelUnderBOnline() throws {
		try cancelUnderB(offline: false)
	}

	func testCancelUnderBOffline() throws {
		try cancelUnderB(offline: true)
	}

	private func cancelUnderB(offline: Bool) throws {
		let app = ReviewRecoveryScreen.unknownSave()
		TutorialHarness.fixtureControl(app, "fixture.switchAthlete")
		TutorialHarness.relaunchKeepingStore(app)
		TutorialHarness.waitForIdentifier(app, "chat.preview.notice", reading: freshReview)
		ReviewRecoveryScreen.assertButtons(transcript(app), .cancelOnly, enabled: true)
		if offline { TutorialHarness.fixtureControl(app, "fixture.failCalendarRead") }
		let before = try receipt(app, key: "athleteB")
		TutorialHarness.attach(
			self, name: "U5-4-B-cancel-only-\(offline ? "offline" : "online")", app: app)
		TutorialHarness.named(app, "chat.preview.cancel").tap()
		assertClosedNote(app)
		XCTAssertEqual(try receipt(app, key: "athleteB"), before, "Cancel sent a request")
		if offline { assertCalendarFaultArmed(app) }
		TutorialHarness.attach(
			self, name: "U5-4-B-cancelled-\(offline ? "offline" : "online")", app: app)
		TutorialHarness.exchange(app, TutorialHarness.workout)
		ReviewRecoveryScreen.assertButtons(transcript(app), .approval, enabled: true)
		assertNote(app)
		XCTAssertEqual(try receipt(app, key: "athleteB").athleteBWrites, 0)
		if offline { assertCalendarFaultArmed(app) }
		TutorialHarness.attach(self, name: "U5-4-B-immediate-fresh-review", app: app)
		TutorialHarness.named(app, "chat.preview.cancel").tap()
		TutorialHarness.relaunchKeepingStore(app)
		assertClosedNote(app)
		TutorialHarness.attach(self, name: "U5-4-B-durable-button-free-note", app: app)
		TutorialHarness.assertZeroFixtureRequests(app)
	}

	private func launch(unknownSave: Bool = false) -> XCUIApplication {
		let app = XCUIApplication()
		TutorialHarness.launch(
			app, arguments: FixtureArguments(calendarSaveFault: unknownSave ? .loseAnswerOnce : nil)
		)
		TutorialHarness.completeOnboarding(app)
		return app
	}

	private func transcript(_ app: XCUIApplication) -> XCUIElement {
		TutorialHarness.named(app, "chat.transcript")
	}

	private func assertClosedNote(_ app: XCUIApplication) {
		assertNote(app)
		ReviewRecoveryScreen.assertButtons(transcript(app), .none, enabled: true)
		XCTAssertFalse(transcript(app).staticTexts["Workout review"].exists)
	}

	private func assertNote(_ app: XCUIApplication) {
		TutorialHarness.waitForIdentifier(app, "chat.note", reading: ReviewRecoveryScreen.cancelled)
		XCTAssertEqual(
			transcript(app).staticTexts.matching(
				NSPredicate(
					format: "identifier == %@ AND label == %@", "chat.note",
					ReviewRecoveryScreen.cancelled)
			).count, 1)
	}

	private func assertCalendarFaultArmed(_ app: XCUIApplication) {
		TutorialHarness.openDebug(app)
		let fault = TutorialHarness.debugRow(app, "fixture.calendarReadFault")
		XCTAssertEqual(fault.label, "Calendar read fault armed")
		TutorialHarness.returnToChat(app)
	}

	private func receipt(_ app: XCUIApplication, key: String) throws -> ReconnectReceipt {
		TutorialHarness.openDebug(app)
		let row = TutorialHarness.debugRow(app, "fixture.peerReceipt")
		TutorialHarness.wait(
			until: { (row.value as? String)?.contains("\"key\":\"\(key)\"") == true },
			message: "Peer receipt did not resolve \(key)")
		let value = try XCTUnwrap(row.value as? String)
		let receipt = try JSONDecoder().decode(ReconnectReceipt.self, from: Data(value.utf8))
		TutorialHarness.returnToChat(app)
		return receipt
	}
}

private struct ReconnectReceipt: Decodable, Equatable {
	let key: String
	let athleteAProfileReads: Int
	let athleteBProfileReads: Int
	let athleteAWrites: Int
	let athleteBWrites: Int
	let athleteACalendarCalls: Int
	let athleteBCalendarCalls: Int
}
