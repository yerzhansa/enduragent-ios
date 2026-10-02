import XCTest

@MainActor
final class DifferentAthleteProof: XCTestCase {
	func testSettingsFlow() {
		TrainingSettingsProofScreen.differentAthlete(self, dark: false)
	}
}

@MainActor
final class DifferentAthleteDarkProof: XCTestCase {
	func testSettingsFlow() {
		TrainingSettingsProofScreen.differentAthlete(self, dark: true)
	}
}

@MainActor
final class SameAthleteRotationProof: XCTestCase {
	func testSettingsFlow() {
		TrainingSettingsProofScreen.rotation(self, dark: false)
	}
}

@MainActor
final class SameAthleteRotationDarkProof: XCTestCase {
	func testSettingsFlow() {
		TrainingSettingsProofScreen.rotation(self, dark: true)
	}
}

@MainActor
final class DisconnectProof: XCTestCase {
	func testSettingsFlow() {
		TrainingSettingsProofScreen.disconnect(self, dark: false)
	}
}

@MainActor
final class DisconnectDarkProof: XCTestCase {
	func testSettingsFlow() {
		TrainingSettingsProofScreen.disconnect(self, dark: true)
	}
}

@MainActor
final class ConnectAfterLaunchProof: XCTestCase {
	func testSettingsFlow() {
		TrainingSettingsProofScreen.connectLater(self, dark: false)
	}
}

@MainActor
final class ConnectAfterLaunchDarkProof: XCTestCase {
	func testSettingsFlow() {
		TrainingSettingsProofScreen.connectLater(self, dark: true)
	}
}

@MainActor
final class FailedWriteRecordsProof: XCTestCase {
	func testSettingsFlow() {
		TrainingSettingsProofScreen.failedWrite(self, dark: false)
	}
}

@MainActor
final class FailedWriteRecordsDarkProof: XCTestCase {
	func testSettingsFlow() {
		TrainingSettingsProofScreen.failedWrite(self, dark: true)
	}
}

@MainActor
final class CredentialTransactionProof: XCTestCase {
	func testSettingsFlow() {
		TrainingSettingsProofScreen.transaction(self, dark: false)
	}
}

@MainActor
final class CredentialTransactionDarkProof: XCTestCase {
	func testSettingsFlow() {
		TrainingSettingsProofScreen.transaction(self, dark: true)
	}
}

@MainActor
final class UnconnectedCalendarProof: XCTestCase {
	func testSettingsFlow() {
		TrainingSettingsProofScreen.unconnectedCalendar(self, dark: false)
	}
}

@MainActor
final class UnconnectedCalendarDarkProof: XCTestCase {
	func testSettingsFlow() {
		TrainingSettingsProofScreen.unconnectedCalendar(self, dark: true)
	}
}

final class UpgradeConnectionProof: XCTestCase {
	func testConnectionFromBeforeTheVaultReachesTheNextTurn() throws {
		let app = XCUIApplication()
		TutorialHarness.launchUpgrade(app, store: .preVault)
		TutorialHarness.wait(TutorialHarness.named(app, "chat.settings"))
		TutorialHarness.openRecords(app)
		let claims = TutorialHarness.recordRowLabels(app).filter { $0.hasPrefix("turnClaim ") }
		TutorialHarness.returnToChat(app)
		XCTAssertEqual(claims.count, 1)
		XCTAssertTrue(claims.allSatisfy { $0.hasSuffix(" unconnected") })
		TutorialHarness.openCredentials(app)
		XCTAssertNotEqual(TutorialHarness.connectedAccount(app), "unconnected")
		TutorialHarness.waitForIdentifier(app, "training.athlete", reading: "Ada Kovač")
		let account = TutorialHarness.connectedAccount(app)
		XCTAssertTrue(account.hasSuffix(":i1001"), "the upgraded connection reads \(account)")
		TutorialHarness.attach(self, name: "upgrade-item", app: app)
		TutorialHarness.returnToChat(app)
		TutorialHarness.exchange(app, TutorialHarness.remember)
		TutorialHarness.waitForLabel(app, TutorialHarness.rememberReply)
		XCTAssertEqual(TutorialHarness.lastClaimAccount(app), account)
	}
}

final class LockedKeychainProof: XCTestCase {
	func testLockedKeychainKeepsTheConversation() {
		let app = XCUIApplication()
		TutorialHarness.launch(app)
		TutorialHarness.completeOnboarding(app)
		TutorialHarness.exchange(app, TutorialHarness.weekQuestion)
		TutorialHarness.waitForLabel(app, TutorialHarness.weekReply)
		TutorialHarness.relaunchKeepingStore(app, keychain: .locked)
		TutorialHarness.waitForIdentifier(
			app, "chat.composer.notice", reading: TutorialHarness.locked)
		XCTAssertTrue(app.staticTexts[TutorialHarness.weekQuestion].exists)
		TutorialHarness.waitForLabel(app, TutorialHarness.weekReply)
		XCTAssertFalse(app.staticTexts[TutorialHarness.notice].exists)
		TutorialHarness.attach(self, name: "locked-keychain", app: app)
		TutorialHarness.assertZeroFixtureRequests(app)
	}
}

final class StorageUnavailableProof: XCTestCase {
	func testUnreadableStoreShowsTheNotice() {
		let app = XCUIApplication()
		TutorialHarness.launch(app, arguments: FixtureArguments(store: .unreadable))
		TutorialHarness.wait(TutorialHarness.named(app, "launch.storageUnavailable"))
		TutorialHarness.waitForLabel(app, "Conversation history is temporarily unavailable.")
		TutorialHarness.waitForLabel(app, "Quit and reopen Enduragent.")
		XCTAssertEqual(app.state, .runningForeground)
		TutorialHarness.attach(self, name: "storage-unavailable", app: app)
	}
}

extension TutorialHarness {
	static func type(_ app: XCUIApplication, _ text: String, into identifier: String) {
		let field = named(app, identifier)
		wait(field, until: .hittable)
		field.tap()
		field.typeText(text)
	}

	static func connectedAccount(_ app: XCUIApplication) -> String {
		returnToChat(app)
		openDebug(app)
		let connection = debugRow(app, "fixture.connection")
		let value = connection.label
		returnToChat(app)
		openCredentials(app)
		return value
	}

	static func lastClaimAccount(_ app: XCUIApplication) -> String? {
		openRecords(app)
		let claim = recordRowLabels(app).last { $0.hasPrefix("turnClaim ") }
		return claim?.split(separator: " ").last.map(String.init)
	}
}
