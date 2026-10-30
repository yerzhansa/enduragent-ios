import EnduragentCoach
import EnduragentCoachFixtures
import XCTest

@MainActor
final class YourDataProof: XCTestCase {
	func testDeleteEverythingOpensOnboardingAsAFreshInstall() {
		let app = YourDataScreen.chatWithOneReply(.erased)
		YourDataScreen.openScreen(app)
		TutorialHarness.attach(self, name: "your-data-screen-light", app: app)
		YourDataScreen.confirm(app, attaching: self)
		YourDataScreen.outcome(app, Catalog.yourDataDone)
		TutorialHarness.attach(self, name: "your-data-done-light", app: app)
		YourDataScreen.continueToOnboarding(app)
		TutorialHarness.attach(self, name: "your-data-onboarding-after-light", app: app)
		YourDataScreen.assertEmptyChatAfterOnboarding(app)
	}

	func testUnreachableCreditsServiceDeletesNothing() {
		let app = YourDataScreen.chatWithOneReply(.unreachable)
		YourDataScreen.openScreen(app)
		YourDataScreen.confirm(app)
		YourDataScreen.outcome(app, Catalog.yourDataNotStarted)
		XCTAssertEqual(
			TutorialHarness.named(app, "yourData.tryAgain").label,
			SupportScreen.say(Catalog.chatTranscriptRetry))
		TutorialHarness.attach(self, name: "your-data-not-started-light", app: app)
		TutorialHarness.named(app, "yourData.tryAgain").tap()
		YourDataScreen.outcome(app, Catalog.yourDataNotStarted)
		TutorialHarness.named(app, "yourData.cancel").tap()
		TutorialHarness.wait(TutorialHarness.named(app, "chat.composer"), until: .hittable)
		XCTAssertEqual(
			TutorialHarness.named(app, "chat.turnProgress").value as? String,
			"turns 1 settled 1")
		TutorialHarness.waitForLabel(app, TutorialHarness.weekReply)
		TutorialHarness.attach(self, name: "your-data-not-started-chat-light", app: app)
	}

	func testICloudLaterFinishesOnThisPhone() {
		let app = YourDataScreen.chatWithOneReply(.iCloudLater)
		YourDataScreen.openScreen(app)
		YourDataScreen.confirm(app)
		YourDataScreen.outcome(app, Catalog.yourDataICloudLater)
		TutorialHarness.attach(self, name: "your-data-icloud-later-light", app: app)
		YourDataScreen.continueToOnboarding(app)
	}

	func testKilledRunResumesOnTheNextLaunch() {
		let app = YourDataScreen.chatWithOneReply(.exportHeld)
		YourDataScreen.openScreen(app)
		YourDataScreen.confirm(app)
		YourDataScreen.outcome(app, Catalog.yourDataProgress)
		TutorialHarness.wait(TutorialHarness.named(app, "yourData.progress"))
		XCTAssertEqual(
			TutorialHarness.named(app, "yourData.progressTime").label,
			SupportScreen.say(Catalog.yourDataProgressTime))
		TutorialHarness.attach(self, name: "your-data-deleting-light", app: app)
		TutorialHarness.relaunchKeepingStore(app, erasure: .iCloudLater)
		YourDataScreen.outcome(app, Catalog.yourDataICloudLater)
		XCTAssertFalse(TutorialHarness.named(app, "chat.composer").exists)
		TutorialHarness.attach(self, name: "your-data-resumed-icloud-later-light", app: app)
		YourDataScreen.continueToOnboarding(app)
	}

	func testAnUnconfirmedCreditsRecordOffersToDeleteThisPhoneAndICloud() {
		let app = YourDataScreen.chatWithOneReply(.refused)
		YourDataScreen.openScreen(app)
		YourDataScreen.confirm(app)
		YourDataScreen.outcome(app, Catalog.yourDataCreditsUnconfirmed)
		XCTAssertEqual(
			TutorialHarness.named(app, "yourData.deleteHere").label,
			SupportScreen.say(Catalog.yourDataDeleteHere))
		XCTAssertTrue(TutorialHarness.named(app, "yourData.cancel").exists)
		XCTAssertFalse(TutorialHarness.named(app, "yourData.tryAgain").exists)
		TutorialHarness.attach(self, name: "your-data-credits-unconfirmed-light", app: app)
		TutorialHarness.named(app, "yourData.deleteHere").tap()
		YourDataScreen.outcome(app, Catalog.yourDataCreditsKeptDone)
		TutorialHarness.attach(self, name: "your-data-credits-kept-done-light", app: app)
		YourDataScreen.continueToOnboarding(app)
		YourDataScreen.assertEmptyChatAfterOnboarding(app)
	}

	func testABusyCreditsServiceSaysToTryAgainLater() {
		let app = YourDataScreen.chatWithOneReply(.rateLimited)
		YourDataScreen.openScreen(app)
		YourDataScreen.confirm(app)
		YourDataScreen.outcome(app, Catalog.yourDataTryLater)
		XCTAssertTrue(TutorialHarness.named(app, "yourData.tryAgain").exists)
		TutorialHarness.attach(self, name: "your-data-try-later-light", app: app)
		TutorialHarness.named(app, "yourData.cancel").tap()
		TutorialHarness.wait(TutorialHarness.named(app, "chat.composer"), until: .hittable)
		XCTAssertEqual(
			TutorialHarness.named(app, "chat.turnProgress").value as? String,
			"turns 1 settled 1")
	}

	func testLargestTextKeepsTheDeletingAndICloudLaterScreensWhole() {
		let app = YourDataScreen.confirmedAtLargestText(.exportHeld)
		YourDataScreen.outcome(app, Catalog.yourDataProgress)
		YourDataScreen.assertWhole(app, ["yourData.outcome", "yourData.progressTime"])
		TutorialHarness.attach(self, name: "largest-en-your-data-deleting-light", app: app)
		TutorialHarness.relaunchKeepingStore(app, erasure: .iCloudLater)
		YourDataScreen.outcome(app, Catalog.yourDataICloudLater)
		YourDataScreen.assertWhole(app, ["yourData.outcome", "yourData.continue"])
		TutorialHarness.attach(self, name: "largest-en-your-data-icloud-later-light", app: app)
	}

	func testLargestTextKeepsTheDoneScreenWhole() {
		let app = YourDataScreen.confirmedAtLargestText(.erased)
		YourDataScreen.outcome(app, Catalog.yourDataDone)
		YourDataScreen.assertWhole(app, ["yourData.outcome", "yourData.continue"])
		TutorialHarness.attach(self, name: "largest-en-your-data-done-light", app: app)
	}

	func testLargestTextKeepsTheCreditsRecordOfferAndItsOutcomeWhole() {
		let app = YourDataScreen.confirmedAtLargestText(.refused)
		YourDataScreen.outcome(app, Catalog.yourDataCreditsUnconfirmed)
		YourDataScreen.assertWhole(
			app, ["yourData.outcome", "yourData.deleteHere", "yourData.cancel"])
		TutorialHarness.attach(
			self, name: "largest-en-your-data-credits-unconfirmed-light", app: app)
		TutorialHarness.named(app, "yourData.deleteHere").tap()
		YourDataScreen.outcome(app, Catalog.yourDataCreditsKeptDone)
		YourDataScreen.assertWhole(app, ["yourData.outcome", "yourData.continue"])
		TutorialHarness.attach(self, name: "largest-en-your-data-credits-kept-done-light", app: app)
	}

	func testLargestTextKeepsTheTryLaterScreenWhole() {
		let app = YourDataScreen.confirmedAtLargestText(.rateLimited)
		YourDataScreen.outcome(app, Catalog.yourDataTryLater)
		YourDataScreen.assertWhole(
			app, ["yourData.outcome", "yourData.tryAgain", "yourData.cancel"])
		TutorialHarness.attach(self, name: "largest-en-your-data-try-later-light", app: app)
	}

	func testLargestTextKeepsEveryLineAndControlWhole() {
		var arguments = FixtureArguments(onboarded: true)
		arguments.erasure = .unreachable
		let run = LargestTextScreen.begin(self, .en, arguments: arguments)
		let app = run.app
		LargestTextScreen.openSettings(app)
		let row = run.named("settings.yourData")
		LargestTextScreen.reveal(app, row, tappable: true)
		XCTAssertEqual(row.label, run.say(Catalog.yourDataDeleteEverything))
		LargestTextScreen.assertWhole(app, row)
		TutorialHarness.attach(self, name: "largest-en-your-data-row-light", app: app)
		row.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
		let keeps = run.named("yourData.keeps")
		TutorialHarness.wait(keeps)
		XCTAssertEqual(keeps.label, run.say(Catalog.yourDataKeeps))
		let window = LargestTextScreen.window(app)
		XCTAssertGreaterThanOrEqual(keeps.frame.minX, window.minX)
		XCTAssertLessThanOrEqual(keeps.frame.maxX, window.maxX)
		let delete = run.named("yourData.delete")
		LargestTextScreen.reveal(app, delete, tappable: true)
		LargestTextScreen.assertWhole(app, delete)
		TutorialHarness.attach(self, name: "largest-en-your-data-screen-light", app: app)
		delete.tap()
		let alert = app.alerts.firstMatch
		TutorialHarness.wait(alert)
		TutorialHarness.attach(self, name: "largest-en-your-data-confirm-light", app: app)
		alert.buttons[run.say(Catalog.yourDataDeleteEverything)].tap()
		YourDataScreen.outcome(app, Catalog.yourDataNotStarted)
		for identifier in ["yourData.outcome", "yourData.tryAgain", "yourData.cancel"] {
			let element = run.named(identifier)
			LargestTextScreen.reveal(app, element, tappable: identifier != "yourData.outcome")
			LargestTextScreen.assertWhole(app, element)
		}
		TutorialHarness.attach(self, name: "largest-en-your-data-not-started-light", app: app)
	}
}

@MainActor
enum YourDataScreen {
	static func chatWithOneReply(_ erasure: FixtureErasure) -> XCUIApplication {
		var arguments = FixtureArguments()
		arguments.erasure = erasure
		let app = SupportScreen.chat(arguments)
		TutorialHarness.exchange(app, TutorialHarness.weekQuestion)
		TutorialHarness.waitForLabel(app, TutorialHarness.weekReply)
		TutorialHarness.openSettings(app)
		return app
	}

	static func confirmedAtLargestText(_ erasure: FixtureErasure) -> XCUIApplication {
		var arguments = FixtureArguments()
		arguments.erasure = erasure
		let app = SupportScreen.chat(arguments)
		TutorialHarness.exchange(app, TutorialHarness.weekQuestion)
		TutorialHarness.waitForLabel(app, TutorialHarness.weekReply)
		ReviewAccessibility.reopenAtLargestText(app, arguments)
		LargestTextScreen.openSettings(app)
		let row = TutorialHarness.named(app, "settings.yourData")
		LargestTextScreen.reveal(app, row, tappable: true)
		row.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
		let delete = TutorialHarness.named(app, "yourData.delete")
		LargestTextScreen.reveal(app, delete, tappable: true)
		delete.tap()
		let alert = app.alerts.firstMatch
		TutorialHarness.wait(alert)
		alert.buttons[SupportScreen.say(Catalog.yourDataDeleteEverything)].tap()
		return app
	}

	private static let lines: Set = ["yourData.outcome", "yourData.progressTime"]

	static func assertWhole(_ app: XCUIApplication, _ identifiers: [String]) {
		for identifier in identifiers {
			let element = TutorialHarness.named(app, identifier)
			if lines.contains(identifier) {
				assertReadable(app, element)
			} else {
				LargestTextScreen.reveal(app, element, tappable: true)
				LargestTextScreen.assertWhole(app, element)
			}
		}
	}

	static func assertReadable(_ app: XCUIApplication, _ line: XCUIElement) {
		TutorialHarness.wait(line)
		let window = LargestTextScreen.window(app)
		XCTAssertGreaterThanOrEqual(
			line.frame.minX, window.minX, "\(line) starts left of the window")
		XCTAssertLessThanOrEqual(line.frame.maxX, window.maxX, "\(line) ends right of the window")
		scroll(app, until: { $0.minY <= line.frame.minY }, forward: false, "the top of \(line)")
		scroll(app, until: { line.frame.maxY <= $0.maxY }, forward: true, "the bottom of \(line)")
	}

	private static func scroll(
		_ app: XCUIApplication, until shown: @escaping (CGRect) -> Bool, forward: Bool,
		_ edge: String
	) {
		TutorialHarness.wait(
			until: {
				let region = LargestTextScreen.visible(app)
				if shown(region) { return true }
				LargestTextScreen.drag(app, in: region, forward: forward)
				return false
			}, within: .retry, message: "\(edge) cannot be scrolled into the screen")
	}

	static func openScreen(_ app: XCUIApplication) {
		SupportScreen.open(app, "settings.yourData", showing: "yourData.keeps")
		XCTAssertEqual(
			TutorialHarness.named(app, "yourData.keeps").label,
			SupportScreen.say(Catalog.yourDataKeeps))
		XCTAssertEqual(
			TutorialHarness.named(app, "yourData.delete").label,
			SupportScreen.say(Catalog.yourDataDeleteEverything))
	}

	static func confirm(_ app: XCUIApplication, attaching test: XCTestCase? = nil) {
		TutorialHarness.named(app, "yourData.delete").tap()
		let alert = app.alerts.firstMatch
		TutorialHarness.wait(alert)
		XCTAssertEqual(alert.label, SupportScreen.say(Catalog.yourDataConfirmTitle))
		XCTAssertTrue(
			alert.staticTexts.matching(
				NSPredicate(format: "label == %@", SupportScreen.say(Catalog.yourDataConfirmBody))
			).firstMatch.exists)
		XCTAssertTrue(alert.buttons[SupportScreen.say(Catalog.commonCancel)].exists)
		if let test { TutorialHarness.attach(test, name: "your-data-confirm-light", app: app) }
		alert.buttons[SupportScreen.say(Catalog.yourDataDeleteEverything)].tap()
	}

	static func outcome(_ app: XCUIApplication, _ key: CatalogKey) {
		SupportScreen.outcome(app, "yourData.outcome", SupportScreen.say(key))
	}

	static func continueToOnboarding(_ app: XCUIApplication) {
		let next = TutorialHarness.named(app, "yourData.continue")
		XCTAssertEqual(next.label, SupportScreen.say(Catalog.commonContinue))
		next.tap()
		TutorialHarness.waitForLabel(app, TutorialHarness.notice)
		TutorialHarness.wait(TutorialHarness.named(app, "notice.continue"), until: .hittable)
	}

	static func assertEmptyChatAfterOnboarding(_ app: XCUIApplication) {
		TutorialHarness.startUnconnected(app)
		TutorialHarness.wait(TutorialHarness.named(app, "chat.composer"), until: .hittable)
		XCTAssertEqual(
			TutorialHarness.named(app, "chat.turnProgress").value as? String,
			"turns 0 settled 0")
		XCTAssertFalse(TutorialHarness.text(app, containing: TutorialHarness.weekReply).exists)
	}
}
