import XCTest

final class InstallOpenProof: XCTestCase {
	func testInstallOpen() {
		let app = XCUIApplication()
		TutorialHarness.launch(app)
		TutorialHarness.waitForLabel(app, TutorialHarness.notice)
		XCTAssertTrue(TutorialHarness.named(app, "notice.continue").exists)
		TutorialHarness.attach(self, name: "01-install-open", app: app)
	}
}

final class ConnectIntervalsProof: XCTestCase {
	func testConnectIntervals() {
		let app = XCUIApplication()
		TutorialHarness.launch(app)
		TutorialHarness.waitForLabel(app, TutorialHarness.notice)
		TutorialHarness.named(app, "notice.continue").tap()
		let key = TutorialHarness.named(app, "connect.apiKey")
		TutorialHarness.wait(key)
		XCTAssertTrue(app.staticTexts["intervals.icu API key"].exists || key.exists)
		key.tap()
		key.typeText("fixture")
		TutorialHarness.named(app, "connect.connect").tap()
		TutorialHarness.wait(TutorialHarness.named(app, "connect.athleteName"))
		XCTAssertEqual(TutorialHarness.named(app, "connect.athleteName").label, "Ada Kovač")
		XCTAssertEqual(TutorialHarness.named(app, "connect.fitness").label, "Fitness 42")
		XCTAssertEqual(TutorialHarness.named(app, "connect.fatigue").label, "Fatigue 49")
		XCTAssertEqual(TutorialHarness.named(app, "connect.form").label, "Form -7")
		TutorialHarness.attach(self, name: "02-connect-intervals", app: app)
	}
}

final class StarterCreditsProof: XCTestCase {
	func testStarterCredits() {
		let app = XCUIApplication()
		TutorialHarness.launch(app)
		TutorialHarness.waitForLabel(app, TutorialHarness.notice)
		TutorialHarness.named(app, "notice.continue").tap()
		let key = TutorialHarness.named(app, "connect.apiKey")
		TutorialHarness.wait(key)
		key.tap()
		key.typeText("fixture")
		TutorialHarness.named(app, "connect.connect").tap()
		TutorialHarness.wait(TutorialHarness.named(app, "connect.continue"))
		TutorialHarness.named(app, "connect.continue").tap()
		let credits = TutorialHarness.named(app, "starter.credits")
		TutorialHarness.wait(credits)
		XCTAssertEqual(credits.label, "200 credits")
		XCTAssertTrue(TutorialHarness.named(app, "starter.start").exists)
		TutorialHarness.attach(self, name: "03-starter-credits", app: app)
	}
}

final class FirstConversationProof: XCTestCase {
	func testFirstConversation() {
		let app = XCUIApplication()
		TutorialHarness.launch(app)
		TutorialHarness.completeOnboarding(app)
		TutorialHarness.send(app, TutorialHarness.weekQuestion)
		TutorialHarness.waitForLabel(app, TutorialHarness.weekReply)
		TutorialHarness.waitForLabel(app, "Training Load")
		TutorialHarness.send(app, TutorialHarness.remember)
		TutorialHarness.waitForLabel(app, TutorialHarness.rememberReply)
		TutorialHarness.attach(self, name: "04-first-conversation", app: app)
		TutorialHarness.assertZeroFixtureRequests(app)
	}
}

final class ReviewProof: XCTestCase {
	func testReview() {
		let app = XCUIApplication()
		TutorialHarness.launch(app)
		TutorialHarness.completeOnboarding(app)
		TutorialHarness.send(app, "/review")
		TutorialHarness.waitForLabel(app, TutorialHarness.reviewReply)
		TutorialHarness.waitForLabel(app, "Training Load")
		TutorialHarness.attach(self, name: "05-review", app: app)
		TutorialHarness.assertZeroFixtureRequests(app)
	}
}

final class CreditsProof: XCTestCase {
	func testCredits() {
		let app = XCUIApplication()
		TutorialHarness.launch(app)
		TutorialHarness.completeOnboarding(app)
		TutorialHarness.openSidebar(app)
		TutorialHarness.named(app, "sidebar.credits").tap()
		let balance = TutorialHarness.named(app, "credits.balance")
		TutorialHarness.wait(balance)
		XCTAssertEqual(balance.label, "200 credits")
		XCTAssertEqual(
			TutorialHarness.named(app, "credits.note").label, "Testers cannot buy packs yet.")
		XCTAssertTrue(
			TutorialHarness.named(app, "credits.pack.icu.enduragent.credits.small").exists)
		XCTAssertTrue(
			TutorialHarness.named(app, "credits.pack.icu.enduragent.credits.large").exists)
		TutorialHarness.attach(self, name: "06-credits", app: app)
	}
}

final class ConfirmedPreviewProof: XCTestCase {
	func testConfirmedPreview() {
		let app = XCUIApplication()
		TutorialHarness.launch(app)
		TutorialHarness.completeOnboarding(app)
		TutorialHarness.send(app, TutorialHarness.workout)
		TutorialHarness.wait(TutorialHarness.named(app, "chat.preview.add"))
		TutorialHarness.waitForLabel(app, "Confirmed preview")
		TutorialHarness.waitForLabel(app, TutorialHarness.warmup)
		XCTAssertTrue(TutorialHarness.named(app, "chat.preview.cancel").exists)
		TutorialHarness.attach(self, name: "07-confirmed-preview", app: app)
		TutorialHarness.assertZeroFixtureRequests(app)
	}
}

final class AddedToCalendarProof: XCTestCase {
	func testAddedToCalendar() {
		let app = XCUIApplication()
		TutorialHarness.launch(app)
		TutorialHarness.completeOnboarding(app)
		TutorialHarness.send(app, TutorialHarness.workout)
		let add = TutorialHarness.named(app, "chat.preview.add")
		TutorialHarness.wait(add)
		add.tap()
		TutorialHarness.waitForLabel(app, TutorialHarness.done)
		TutorialHarness.attach(self, name: "07b-added-to-calendar", app: app)
		TutorialHarness.assertZeroFixtureRequests(app)
	}
}

final class SlashListNoPlanProof: XCTestCase {
	func testSlashListHidesPlan() {
		let app = XCUIApplication()
		TutorialHarness.launch(app)
		TutorialHarness.completeOnboarding(app)
		let composer = TutorialHarness.named(app, "chat.composer")
		composer.tap()
		composer.typeText("/")
		TutorialHarness.wait(TutorialHarness.named(app, "chat.slash.review"))
		XCTAssertTrue(TutorialHarness.named(app, "chat.slash.status").exists)
		XCTAssertTrue(TutorialHarness.named(app, "chat.slash.workout").exists)
		XCTAssertTrue(TutorialHarness.named(app, "chat.slash.language").exists)
		XCTAssertFalse(TutorialHarness.named(app, "chat.slash.plan").exists)
		TutorialHarness.attach(self, name: "slash-list-no-plan", app: app)
	}
}

final class HistoryListProof: XCTestCase {
	func testHistoryList() {
		let app = XCUIApplication()
		TutorialHarness.launch(app)
		TutorialHarness.completeOnboarding(app)
		TutorialHarness.send(app, TutorialHarness.weekQuestion)
		TutorialHarness.waitForLabel(app, TutorialHarness.weekReply)
		TutorialHarness.assertZeroFixtureRequests(app)
		TutorialHarness.openSidebar(app)
		TutorialHarness.named(app, "sidebar.history").tap()
		let row = app.descendants(matching: .any).matching(
			NSPredicate(format: "identifier BEGINSWITH %@", "history.row.")
		).firstMatch
		TutorialHarness.wait(row)
		TutorialHarness.waitForLabel(app, TutorialHarness.weekQuestion)
		TutorialHarness.waitForLabel(app, "1998-06-15")
		TutorialHarness.attach(self, name: "history-list", app: app)
	}
}

final class ConfirmedPreviewDarkProof: XCTestCase {
	func testConfirmedPreviewDark() {
		let app = XCUIApplication()
		TutorialHarness.launch(app, dark: true)
		TutorialHarness.completeOnboarding(app)
		TutorialHarness.send(app, TutorialHarness.workout)
		TutorialHarness.wait(TutorialHarness.named(app, "chat.preview.add"))
		TutorialHarness.waitForLabel(app, "Confirmed preview")
		TutorialHarness.attach(self, name: "07-confirmed-preview-dark", app: app)
		TutorialHarness.assertZeroFixtureRequests(app)
	}
}

final class RelaunchKeepsChatProof: XCTestCase {
	func testRelaunchKeepsChat() {
		let app = XCUIApplication()
		TutorialHarness.launch(app)
		TutorialHarness.completeOnboarding(app)
		TutorialHarness.send(app, TutorialHarness.weekQuestion)
		TutorialHarness.waitForLabel(app, TutorialHarness.weekReply)
		TutorialHarness.relaunchKeepingStore(app)
		TutorialHarness.wait(TutorialHarness.named(app, "chat.composer"))
		TutorialHarness.waitForLabel(app, TutorialHarness.weekQuestion)
		TutorialHarness.waitForLabel(app, TutorialHarness.weekReply)
		XCTAssertFalse(app.staticTexts[TutorialHarness.notice].exists)
		TutorialHarness.attach(self, name: "relaunch-keeps-chat", app: app)
		TutorialHarness.assertZeroFixtureRequests(app)
	}
}

final class RecordsAfterReplyProof: XCTestCase {
	func testRecordsAfterReply() {
		let app = XCUIApplication()
		TutorialHarness.launch(app)
		TutorialHarness.completeOnboarding(app)
		TutorialHarness.send(app, TutorialHarness.weekQuestion)
		TutorialHarness.waitForLabel(app, TutorialHarness.weekReply)
		TutorialHarness.openRecords(app)
		XCTAssertEqual(TutorialHarness.recordCount(app, "userMessage"), "userMessage 1")
		XCTAssertEqual(TutorialHarness.recordCount(app, "turnClaim"), "turnClaim 1")
		XCTAssertEqual(TutorialHarness.recordCount(app, "turnSettled"), "turnSettled 1")
		XCTAssertNil(TutorialHarness.recordCount(app, "assistantMessage"))
		TutorialHarness.attach(self, name: "records-after-reply", app: app)
	}
}

final class RecordsClockOrderProof: XCTestCase {
	func testRecordsClockOrder() {
		let app = XCUIApplication()
		TutorialHarness.launch(app)
		TutorialHarness.completeOnboarding(app)
		TutorialHarness.send(app, TutorialHarness.weekQuestion)
		TutorialHarness.waitForLabel(app, TutorialHarness.weekReply)
		TutorialHarness.send(app, TutorialHarness.workout)
		TutorialHarness.wait(TutorialHarness.named(app, "chat.preview.add"))
		TutorialHarness.named(app, "chat.preview.add").tap()
		TutorialHarness.waitForLabel(app, TutorialHarness.done)
		TutorialHarness.openRecords(app)
		TutorialHarness.attach(self, name: "records-clock-order", app: app)
		let labels = TutorialHarness.recordRowLabels(app)
		let rows = labels.map { $0.split(separator: " ").map(String.init) }
		XCTAssertTrue(
			rows.allSatisfy { $0.count == 3 }, "every row shows kind, device, and HLC: \(labels)")
		let clocks = rows.compactMap(\.last)
		XCTAssertEqual(Set(clocks).count, clocks.count, "no two rows share an HLC: \(labels)")
		let causal = rows.compactMap(\.first).filter {
			["userMessage", "turnClaim", "turnSettled", "pendingProposal", "proposalCleared"]
				.contains($0)
		}
		XCTAssertEqual(
			causal,
			[
				"userMessage", "turnClaim", "turnSettled", "userMessage", "turnClaim",
				"pendingProposal", "turnSettled", "proposalCleared",
			],
			"rows in HLC order follow the order the app wrote them: \(labels)")
	}
}

final class UpgradeKeepsTranscriptProof: XCTestCase {
	func testUpgradeKeepsTranscript() throws {
		let app = XCUIApplication()
		try TutorialHarness.launchKeepingStore(
			app, expecting: app.staticTexts[TutorialHarness.weekQuestion])
		TutorialHarness.wait(TutorialHarness.named(app, "chat.composer"))
		TutorialHarness.waitForLabel(app, TutorialHarness.weekReply)
		TutorialHarness.openRecords(app)
		XCTAssertEqual(
			TutorialHarness.recordCount(app, "assistantMessage"), "assistantMessage 1")
		TutorialHarness.attach(self, name: "upgrade-transcript", app: app)
		TutorialHarness.closeMenu(app)
		TutorialHarness.send(app, TutorialHarness.remember)
		TutorialHarness.waitForLabel(app, TutorialHarness.rememberReply)
		TutorialHarness.waitForLabel(app, TutorialHarness.weekQuestion)
		TutorialHarness.attach(self, name: "upgrade-then-reply", app: app)
		TutorialHarness.openRecords(app)
		XCTAssertEqual(TutorialHarness.recordCount(app, "turnSettled"), "turnSettled 1")
		XCTAssertEqual(
			TutorialHarness.recordCount(app, "assistantMessage"), "assistantMessage 1")
		TutorialHarness.attach(self, name: "upgrade-then-reply-records", app: app)
	}
}

final class UpgradeKeepsProposalProof: XCTestCase {
	func testUpgradeKeepsProposal() throws {
		let app = XCUIApplication()
		try TutorialHarness.launchKeepingStore(
			app, expecting: TutorialHarness.named(app, "chat.preview.add"))
		TutorialHarness.waitForLabel(app, "Confirmed preview")
		let cancel = TutorialHarness.named(app, "chat.preview.cancel")
		let add = TutorialHarness.named(app, "chat.preview.add")
		XCTAssertTrue(cancel.exists)
		XCTAssertLessThan(cancel.frame.minX, add.frame.minX)
		TutorialHarness.attach(self, name: "upgrade-proposal", app: app)
	}
}
