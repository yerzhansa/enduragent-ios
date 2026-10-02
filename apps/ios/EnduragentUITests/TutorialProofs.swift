import EnduragentCoach
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
		XCTAssertEqual(key.elementType, .secureTextField)
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
	func testDebugStarterUsesInjectedDeviceCheck() {
		let app = XCUIApplication()
		TutorialHarness.launch(app)
		TutorialHarness.completeOnboarding(app)
		TutorialHarness.openSidebar(app)
		TutorialHarness.named(app, "sidebar.debug").tap()
		let credits = TutorialHarness.named(app, "debug.credits")
		TutorialHarness.wait(credits, until: .hittable)
		credits.tap()
		let claim = TutorialHarness.named(app, "debug.credits.claimStarter")
		TutorialHarness.wait(claim, until: .hittable)
		claim.tap()
		TutorialHarness.waitForIdentifier(
			app, "debug.credits.starterNotice", reading: "200 credits")
		TutorialHarness.attach(self, name: "debug-starter-credits", app: app)
	}

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
		TutorialHarness.exchange(app, TutorialHarness.weekQuestion)
		TutorialHarness.waitForLabel(app, TutorialHarness.weekReply)
		TutorialHarness.waitForLabel(app, "Training Load")
		TutorialHarness.exchange(app, TutorialHarness.remember)
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
		TutorialHarness.exchange(app, "/review")
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

final class SlashListNoPlanProof: XCTestCase {
	func testSlashListHidesPlan() {
		let app = XCUIApplication()
		TutorialHarness.launch(app)
		TutorialHarness.completeOnboarding(app)
		let composer = TutorialHarness.named(app, "chat.composer")
		composer.tap()
		composer.typeText("/")
		TutorialHarness.wait(TutorialHarness.named(app, "chat.slash.review"))
		XCTAssertTrue(TutorialHarness.named(app, "chat.slash.start").exists)
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
		TutorialHarness.exchange(app, TutorialHarness.weekQuestion)
		TutorialHarness.waitForLabel(app, TutorialHarness.weekReply)
		TutorialHarness.openHistory(app)
		TutorialHarness.waitForLabel(app, "No past conversations yet.")
		XCTAssertFalse(TutorialHarness.historyRows(app).firstMatch.exists)
		TutorialHarness.attach(self, name: "history-empty", app: app)
		TutorialHarness.closeMenu(app)
		TutorialHarness.send(app, "/start")
		TutorialHarness.waitForWelcome(app)
		TutorialHarness.waitForLabel(app, TutorialHarness.newConversationStarted)
		TutorialHarness.openHistory(app)
		let row = TutorialHarness.historyRows(app).firstMatch
		TutorialHarness.wait(row)
		XCTAssertEqual(TutorialHarness.historyRows(app).count, 1)
		TutorialHarness.waitForLabel(app, TutorialHarness.weekQuestion)
		TutorialHarness.waitForLabel(app, TutorialHarness.startedNewConversation)
		TutorialHarness.waitForLabel(app, "1998-06-15")
		TutorialHarness.attach(self, name: "history-list", app: app)
		TutorialHarness.closeMenu(app)
		TutorialHarness.assertZeroFixtureRequests(app)
	}
}

final class NewConversationProof: XCTestCase {
	func testNewConversation() {
		let app = XCUIApplication()
		TutorialHarness.launch(app)
		TutorialHarness.completeOnboarding(app)
		TutorialHarness.exchange(app, TutorialHarness.weekQuestion)
		TutorialHarness.waitForLabel(app, TutorialHarness.weekReply)
		let button = TutorialHarness.named(app, "chat.newConversation")
		TutorialHarness.wait(button, until: .hittable)
		let phrasebook = CatalogPhrasebook(tag: .en)
		XCTAssertEqual(button.label, phrasebook.say(Catalog.chatNewConversationLabel))
		XCTAssertEqual(button.elementType, .button)
		TutorialHarness.assertIconButtonWidth(button)
		TutorialHarness.attach(self, name: "new-conversation-compose-icon", app: app)
		let welcome = TutorialHarness.named(app, "chat.welcome")
		let tapped = Date()
		button.tap()
		TutorialHarness.wait(welcome, within: .turn)
		let latency = Date().timeIntervalSince(tapped)
		TutorialHarness.waitForWelcome(app)
		let sample = XCTAttachment(string: String(format: "%.0f", latency * 1_000))
		sample.name = "new-conversation-latency-ms"
		sample.lifetime = .keepAlways
		add(sample)
		let notice = TutorialHarness.named(app, "chat.newConversation.notice")
		TutorialHarness.wait(notice)
		XCTAssertEqual(notice.label, TutorialHarness.newConversationStarted)
		XCTAssertFalse(app.staticTexts[TutorialHarness.weekQuestion].exists)
		TutorialHarness.attach(self, name: "new-conversation", app: app)
		TutorialHarness.openRecords(app)
		XCTAssertEqual(TutorialHarness.recordCount(app, "windowStart"), "windowStart 1")
		XCTAssertEqual(TutorialHarness.recordCount(app, "flushPending"), "flushPending 1")
		XCTAssertEqual(TutorialHarness.recordCount(app, "flushSettled"), "flushSettled 1")
		TutorialHarness.attach(self, name: "new-conversation-records", app: app)
	}
}

final class NewConversationWorkingProof: XCTestCase {
	func testWorkingWhileMemorySaves() {
		let app = XCUIApplication()
		TutorialHarness.launch(app)
		TutorialHarness.completeOnboarding(app)
		TutorialHarness.exchange(app, "fixture:slow-flush")
		let button = TutorialHarness.named(app, "chat.newConversation")
		TutorialHarness.wait(button, until: .hittable)
		button.tap()
		let working = TutorialHarness.named(app, "chat.working")
		TutorialHarness.wait(working, within: .screen)
		XCTAssertEqual(working.label, "Starting a new conversation…")
		XCTAssertFalse(TutorialHarness.named(app, "chat.welcome").exists)
		TutorialHarness.attach(self, name: "new-conversation-working", app: app)
		TutorialHarness.waitForWelcome(app)
		TutorialHarness.wait(working, until: .absent)
		TutorialHarness.waitForLabel(app, TutorialHarness.newConversationStarted)
	}
}

final class HistoryArchivedProof: XCTestCase {
	func testHistoryArchived() {
		let app = XCUIApplication()
		TutorialHarness.launch(app)
		TutorialHarness.completeOnboarding(app)
		TutorialHarness.exchange(app, TutorialHarness.weekQuestion)
		TutorialHarness.waitForLabel(app, TutorialHarness.weekReply)
		TutorialHarness.startNewConversation(app)
		TutorialHarness.openHistory(app)
		let row = TutorialHarness.historyRows(app).firstMatch
		TutorialHarness.wait(row)
		TutorialHarness.waitForLabel(app, TutorialHarness.startedNewConversation)
		TutorialHarness.attach(self, name: "history-row", app: app)
		row.tap()
		TutorialHarness.wait(TutorialHarness.named(app, "archive.readOnly"))
		XCTAssertEqual(
			TutorialHarness.named(app, "archive.readOnly").label, TutorialHarness.readOnly)
		TutorialHarness.waitForLabel(app, TutorialHarness.weekQuestion)
		TutorialHarness.waitForLabel(app, TutorialHarness.weekReply)
		XCTAssertFalse(TutorialHarness.named(app, "chat.composer").isHittable)
		XCTAssertFalse(TutorialHarness.named(app, "chat.send").isHittable)
		TutorialHarness.attach(self, name: "history-archived", app: app)
	}
}

final class RelaunchKeepsChatProof: XCTestCase {
	func testRelaunchKeepsChat() {
		let app = XCUIApplication()
		TutorialHarness.launch(app)
		TutorialHarness.completeOnboarding(app)
		TutorialHarness.exchange(app, TutorialHarness.weekQuestion)
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
		TutorialHarness.exchange(app, TutorialHarness.weekQuestion)
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
		TutorialHarness.exchange(app, TutorialHarness.weekQuestion)
		TutorialHarness.waitForLabel(app, TutorialHarness.weekReply)
		TutorialHarness.exchange(app, TutorialHarness.workout)
		let add = TutorialHarness.named(app, "chat.preview.add")
		TutorialHarness.wait(add, until: .enabled)
		add.tap()
		TutorialHarness.waitForLabel(app, TutorialHarness.done)
		TutorialHarness.openRecords(app)
		TutorialHarness.attach(self, name: "records-clock-order", app: app)
		let labels = TutorialHarness.recordRowLabels(app)
		let rows = labels.map { $0.split(separator: " ").map(String.init) }
		XCTAssertTrue(
			rows.allSatisfy {
				$0.count == 4
					|| (["turnSettled", "turnClaim", "proposalCleared"].contains($0.first)
						&& $0.count > 4)
			},
			"every row shows kind, device, HLC, account, and any settlement, lease, or clear outcome: \(labels)"
		)
		let clocks = rows.compactMap { $0.dropLast().last }
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

final class UpgradeHistoryProof: XCTestCase {
	func testUpgradeHistory() throws {
		let app = XCUIApplication()
		TutorialHarness.launchUpgrade(app, store: .v1History)
		TutorialHarness.waitForWelcome(app)
		XCTAssertFalse(app.staticTexts[TutorialHarness.weekQuestion].exists)
		XCTAssertFalse(TutorialHarness.named(app, "chat.newConversation.notice").exists)
		TutorialHarness.attach(self, name: "upgrade-welcome", app: app)
		TutorialHarness.openHistory(app)
		let rows = TutorialHarness.historyRows(app)
		TutorialHarness.wait(rows.firstMatch)
		XCTAssertEqual(rows.count, 2)
		let earlier = app.staticTexts.matching(
			NSPredicate(format: "label == %@", TutorialHarness.earlierChat))
		XCTAssertEqual(earlier.count, 2)
		TutorialHarness.waitForLabel(app, TutorialHarness.weekQuestion)
		TutorialHarness.waitForLabel(app, TutorialHarness.remember)
		TutorialHarness.attach(self, name: "upgrade-history", app: app)
		rows.element(boundBy: 1).tap()
		TutorialHarness.wait(TutorialHarness.named(app, "archive.readOnly"))
		TutorialHarness.waitForLabel(app, TutorialHarness.weekQuestion)
		TutorialHarness.waitForLabel(app, TutorialHarness.weekReply)
		XCTAssertFalse(TutorialHarness.named(app, "chat.composer").isHittable)
		XCTAssertFalse(TutorialHarness.named(app, "chat.send").isHittable)
		TutorialHarness.attach(self, name: "upgrade-history-read-only", app: app)
	}
}
