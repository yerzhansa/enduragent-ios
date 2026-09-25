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

final class SlowReplyProof: XCTestCase {
	func testSlowReply() {
		let app = XCUIApplication()
		TutorialHarness.launch(app)
		TutorialHarness.completeOnboarding(app)
		TutorialHarness.send(app, "fixture:slow")
		let working = TutorialHarness.named(app, "chat.working")
		TutorialHarness.wait(working, timeout: 2)
		XCTAssertEqual(working.label, TutorialHarness.working)
		TutorialHarness.attach(self, name: "slow-reply-working", app: app)
		TutorialHarness.waitForLabel(app, "This week has", timeout: 5)
		XCTAssertFalse(app.staticTexts["quieter stretch between them."].exists)
		TutorialHarness.attach(self, name: "slow-reply-streaming", app: app)
		TutorialHarness.waitForLabel(app, "quieter stretch between them.", timeout: 15)
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
		TutorialHarness.send(app, "fixture:fail 500")
		let error = TutorialHarness.named(app, "chat.error")
		TutorialHarness.wait(error)
		XCTAssertEqual(error.label, TutorialHarness.responseFailure)
		XCTAssertFalse(
			app.staticTexts.containing(
				NSPredicate(format: "label CONTAINS %@", "OpenRouterHTTPError")
			).firstMatch.exists)
		TutorialHarness.attach(self, name: "failed-reply", app: app)
		TutorialHarness.assertZeroFixtureRequests(app)
	}
}
