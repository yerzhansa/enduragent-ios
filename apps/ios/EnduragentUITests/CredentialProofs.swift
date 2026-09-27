import XCTest

final class DifferentAthleteProof: XCTestCase {
	func testDifferentAthleteIsRefusedThenSwitchHidesAdd() {
		let app = XCUIApplication()
		TutorialHarness.launch(app)
		TutorialHarness.completeOnboarding(app)
		TutorialHarness.send(app, TutorialHarness.workout)
		TutorialHarness.wait(TutorialHarness.named(app, "chat.preview.add"))
		TutorialHarness.openCredentials(app)
		let account = TutorialHarness.connectedAccount(app)
		TutorialHarness.type(app, "other-athlete", into: "credentials.apiKey")
		TutorialHarness.named(app, "credentials.replace").tap()
		TutorialHarness.waitForIdentifier(
			app, "credentials.outcome", reading: TutorialHarness.otherAthleteRefused)
		TutorialHarness.waitForIdentifier(app, "credentials.athlete", reading: "Ada Kovač")
		TutorialHarness.attach(self, name: "different-athlete", app: app)
		TutorialHarness.closeMenu(app)
		XCTAssertTrue(TutorialHarness.named(app, "chat.preview.add").exists)
		TutorialHarness.send(app, TutorialHarness.weekQuestion)
		TutorialHarness.waitForLabel(app, TutorialHarness.weekReply)
		XCTAssertEqual(TutorialHarness.lastClaimAccount(app), account)
		TutorialHarness.closeMenu(app)
		TutorialHarness.openCredentials(app)
		TutorialHarness.type(app, "other-athlete", into: "credentials.apiKey")
		TutorialHarness.named(app, "credentials.switchAthlete").tap()
		TutorialHarness.waitForIdentifier(app, "credentials.athlete", reading: "Bo Lind")
		TutorialHarness.closeMenu(app)
		TutorialHarness.wait(TutorialHarness.named(app, "chat.preview.cancel"))
		XCTAssertFalse(TutorialHarness.named(app, "chat.preview.add").exists)
		TutorialHarness.attach(self, name: "switch-confirmed", app: app)
		TutorialHarness.assertZeroFixtureRequests(app)
	}
}

final class DisconnectProof: XCTestCase {
	func testDisconnectLeavesTheNextTurnUnconnected() {
		let app = XCUIApplication()
		TutorialHarness.launch(app)
		TutorialHarness.completeOnboarding(app)
		TutorialHarness.openCredentials(app)
		TutorialHarness.named(app, "credentials.disconnect").tap()
		TutorialHarness.waitForIdentifier(app, "credentials.outcome", reading: "Disconnected.")
		TutorialHarness.waitForIdentifier(app, "credentials.connection", reading: "unconnected")
		TutorialHarness.closeMenu(app)
		TutorialHarness.send(app, TutorialHarness.weekQuestion)
		TutorialHarness.waitForLabel(app, TutorialHarness.weekReply)
		XCTAssertEqual(TutorialHarness.lastClaimAccount(app), "unconnected")
		TutorialHarness.attach(self, name: "disconnect", app: app)
	}
}

final class ConnectAfterLaunchProof: XCTestCase {
	func testKeyStoredAfterSkipReachesTheNextTurn() {
		let app = XCUIApplication()
		TutorialHarness.launch(app)
		TutorialHarness.waitForLabel(app, TutorialHarness.notice)
		TutorialHarness.named(app, "notice.continue").tap()
		let skip = TutorialHarness.named(app, "connect.skip")
		TutorialHarness.wait(skip)
		skip.tap()
		let start = TutorialHarness.named(app, "starter.start")
		TutorialHarness.wait(start)
		start.tap()
		TutorialHarness.send(app, TutorialHarness.weekQuestion)
		TutorialHarness.waitForLabel(app, TutorialHarness.weekReply)
		XCTAssertEqual(TutorialHarness.lastClaimAccount(app), "unconnected")
		TutorialHarness.closeMenu(app)
		TutorialHarness.openCredentials(app)
		TutorialHarness.type(app, "fixture", into: "credentials.apiKey")
		TutorialHarness.named(app, "credentials.replace").tap()
		TutorialHarness.waitForIdentifier(app, "credentials.athlete", reading: "Ada Kovač")
		let account = TutorialHarness.connectedAccount(app)
		TutorialHarness.closeMenu(app)
		TutorialHarness.send(app, TutorialHarness.remember)
		TutorialHarness.waitForLabel(app, TutorialHarness.rememberReply)
		XCTAssertEqual(TutorialHarness.lastClaimAccount(app), account)
		TutorialHarness.attach(self, name: "connect-after-launch", app: app)
	}
}

final class FailedWriteRecordsProof: XCTestCase {
	func testFailedWriteKeepsTheOldConnectionForTheNextTurn() {
		let app = XCUIApplication()
		TutorialHarness.launch(app)
		TutorialHarness.completeOnboarding(app)
		TutorialHarness.openCredentials(app)
		let account = TutorialHarness.connectedAccount(app)
		TutorialHarness.named(app, "credentials.failNextWrite").tap()
		TutorialHarness.type(app, "fixture-2", into: "credentials.apiKey")
		TutorialHarness.named(app, "credentials.replace").tap()
		TutorialHarness.waitForIdentifier(
			app, "credentials.outcome", reading: TutorialHarness.previousKeyKept)
		TutorialHarness.attach(self, name: "failed-write", app: app)
		TutorialHarness.closeMenu(app)
		TutorialHarness.send(app, TutorialHarness.weekQuestion)
		TutorialHarness.waitForLabel(app, TutorialHarness.weekReply)
		XCTAssertEqual(TutorialHarness.lastClaimAccount(app), account)
		TutorialHarness.attach(self, name: "failed-write-records", app: app)
	}
}

final class UpgradeConnectionProof: XCTestCase {
	func testV1ConnectionShowsAFreshIdAndTheAthlete() throws {
		let app = XCUIApplication()
		try TutorialHarness.launchKeepingStore(
			app, expecting: TutorialHarness.named(app, "chat.composer"))
		TutorialHarness.openCredentials(app)
		TutorialHarness.waitForIdentifier(app, "credentials.athlete", reading: "Ada Kovač")
		XCTAssertTrue(TutorialHarness.connectedAccount(app).hasSuffix(":i1001"))
		TutorialHarness.attach(self, name: "upgrade-item", app: app)
	}
}

extension TutorialHarness {
	static let otherAthleteRefused =
		"This key belongs to athlete i2002, not i1001. Switch athlete to use it."

	static func type(_ app: XCUIApplication, _ text: String, into identifier: String) {
		let field = named(app, identifier)
		wait(field)
		field.tap()
		field.typeText(text)
	}

	static func connectedAccount(_ app: XCUIApplication) -> String {
		let connection = named(app, "credentials.connection")
		wait(connection)
		let parts = connection.label.split(separator: " ")
		XCTAssertEqual(parts.count, 2, "credentials.connection reads \(connection.label)")
		return "intervals:\(parts.first ?? ""):\(parts.last ?? "")"
	}

	static func lastClaimAccount(_ app: XCUIApplication) -> String? {
		openRecords(app)
		let claim = recordRowLabels(app).last { $0.hasPrefix("turnClaim ") }
		return claim?.split(separator: " ").last.map(String.init)
	}
}
