import EnduragentCoach
import EnduragentCoachFixtures
import XCTest

@MainActor
final class SupportSectionProof: XCTestCase {
	func testSectionOrderAndRows() {
		let app = SupportScreen.start()
		let support = TutorialHarness.text(
			app, containing: SupportScreen.say(Catalog.settingsSupportTitle))
		let session = TutorialHarness.named(app, "settings.session")
		let rows = ["settings.feedback", "settings.diagnostics", "settings.about"].map {
			TutorialHarness.named(app, $0)
		}
		TutorialHarness.scroll(app, to: rows[2])
		XCTAssertEqual(
			rows.map(\.label),
			[Catalog.feedbackTitle, Catalog.diagnosticsTitle, Catalog.aboutTitle].map(
				SupportScreen.say))
		TutorialHarness.wait(support)
		XCTAssertLessThan(session.frame.maxY, support.frame.minY)
		XCTAssertLessThan(support.frame.maxY, rows[0].frame.minY)
		XCTAssertLessThan(rows[0].frame.maxY, rows[1].frame.minY)
		XCTAssertLessThan(rows[1].frame.maxY, rows[2].frame.minY)
		TutorialHarness.attach(self, name: "support-section-light", app: app)
		let screens = [
			("settings.feedback", "feedback.field"),
			("settings.diagnostics", "diagnostics.make"),
			("settings.about", "about.version"),
		]
		for (row, content) in screens {
			let link = TutorialHarness.named(app, row)
			TutorialHarness.scroll(app, to: link)
			link.tap()
			TutorialHarness.wait(TutorialHarness.named(app, content))
			app.navigationBars.buttons.element(boundBy: 0).tap()
			TutorialHarness.wait(link, until: .hittable)
		}
	}
}

@MainActor
final class FeedbackScreenProof: XCTestCase {
	func testRefusals() {
		let app = SupportScreen.start()
		SupportScreen.open(app, "settings.feedback", showing: "feedback.field")
		TutorialHarness.named(app, "feedback.send").tap()
		SupportScreen.outcome(
			app, "feedback.outcome", SupportScreen.say(Catalog.feedbackRefusedEmpty))
		let field = TutorialHarness.named(app, "feedback.field")
		field.tap()
		field.typeText(String(repeating: "a", count: FeedbackRefusal.limit + 1))
		let send = TutorialHarness.named(app, "feedback.send")
		TutorialHarness.scroll(app, to: send)
		send.tap()
		SupportScreen.outcome(
			app, "feedback.outcome",
			SupportScreen.phrasebook.say(Catalog.feedbackRefusedTooLong, ["limit": "4,000"]))
		TutorialHarness.attach(self, name: "feedback-too-long-light", app: app)
		SupportScreen.assertFeedbackCounts(app, requests: 0, stored: 0)
	}

	func testTraceLostLostThenTryAgain() {
		let app = SupportScreen.start(feedback: "lost,lost")
		SupportScreen.open(app, "settings.feedback", showing: "feedback.field")
		let field = TutorialHarness.named(app, "feedback.field")
		field.tap()
		field.typeText(SupportScreen.note)
		TutorialHarness.named(app, "feedback.send").tap()
		SupportScreen.outcome(
			app, "feedback.outcome", SupportScreen.say(Catalog.feedbackNotConfirmed))
		XCTAssertEqual(field.value as? String, SupportScreen.note)
		TutorialHarness.attach(self, name: "feedback-not-confirmed-light", app: app)
		SupportScreen.tryAgain(app)
		SupportScreen.assertFeedbackCounts(app, requests: 3, stored: 1)
	}

	func testRelaunchKeepsNotConfirmedNoteAndTryAgainSendsIt() {
		let app = SupportScreen.start(feedback: "lost,lost")
		SupportScreen.open(app, "settings.feedback", showing: "feedback.field")
		let field = TutorialHarness.named(app, "feedback.field")
		field.tap()
		field.typeText(SupportScreen.note)
		TutorialHarness.named(app, "feedback.send").tap()
		SupportScreen.outcome(
			app, "feedback.outcome", SupportScreen.say(Catalog.feedbackNotConfirmed))
		TutorialHarness.relaunchKeepingStore(app, clearingFeedbackScript: true)
		TutorialHarness.wait(TutorialHarness.named(app, "chat.composer"))
		TutorialHarness.openSettings(app)
		SupportScreen.open(app, "settings.feedback", showing: "feedback.field")
		TutorialHarness.wait(field, until: .value(SupportScreen.note))
		SupportScreen.outcome(
			app, "feedback.outcome", SupportScreen.say(Catalog.feedbackNotConfirmed))
		TutorialHarness.attach(self, name: "feedback-kept-after-relaunch-light", app: app)
		SupportScreen.tryAgain(app)
		SupportScreen.assertFeedbackCounts(app, requests: 1, stored: 1)
	}
}

@MainActor
final class DiagnosticsScreenProof: XCTestCase {
	func testCancelShowsCanceled() {
		let app = SupportScreen.startSharing()
		let close = app.buttons[SupportScreen.closeShareSheet]
		TutorialHarness.wait(close, until: .hittable)
		close.tap()
		SupportScreen.outcome(
			app, "diagnostics.outcome", SupportScreen.say(Catalog.diagnosticsCanceled))
		let make = TutorialHarness.named(app, "diagnostics.make")
		TutorialHarness.wait(make, until: .enabled)
		TutorialHarness.attach(self, name: "diagnostics-canceled-light", app: app)
		make.tap()
		TutorialHarness.wait(close, until: .hittable)
		close.tap()
		TutorialHarness.wait(make, until: .enabled)
	}

	func testCopyShowsShared() {
		let app = SupportScreen.startSharing()
		SupportScreen.shareAction(app, "Copy").tap()
		SupportScreen.outcome(
			app, "diagnostics.outcome", SupportScreen.say(Catalog.diagnosticsShared))
		TutorialHarness.wait(TutorialHarness.named(app, "diagnostics.make"), until: .enabled)
		TutorialHarness.attach(self, name: "diagnostics-shared-light", app: app)
	}

	func testSaveToFilesOnMyIPhoneShowsSaved() {
		let app = SupportScreen.startSharing()
		SupportScreen.shareAction(app, "Save to Files").tap()
		let onMyIPhone = SupportScreen.shareAction(app, "On My iPhone")
		TutorialHarness.wait(onMyIPhone, until: .hittable)
		onMyIPhone.tap()
		let save = app.buttons["Save"]
		TutorialHarness.wait(save, until: .enabled)
		save.tap()
		SupportScreen.outcome(
			app, "diagnostics.outcome", SupportScreen.say(Catalog.diagnosticsSaved))
		TutorialHarness.attach(self, name: "diagnostics-saved-light", app: app)
	}

	func testNotSavingLine() {
		var arguments = FixtureArguments()
		arguments.journal = .notSaving
		let app = SupportScreen.start(arguments)
		SupportScreen.open(app, "settings.diagnostics", showing: "diagnostics.make")
		SupportScreen.outcome(app, "diagnostics.notSaving", SupportScreen.notSavingSentence)
		TutorialHarness.attach(self, name: "diagnostics-not-saving-light", app: app)
	}
}

@MainActor
final class AboutScreenProof: XCTestCase {
	func testNameVersionAndLink() {
		let app = SupportScreen.start()
		SupportScreen.open(app, "settings.about", showing: "about.version")
		SupportScreen.outcome(app, "about.value.name", "Enduragent")
		SupportScreen.outcome(
			app, "about.version",
			SupportScreen.phrasebook.say(
				Catalog.settingsApplicationVersion, ["version": "0.1.0 (3)"]))
		let link = TutorialHarness.named(app, "about.privacyPolicy")
		XCTAssertEqual(link.label, SupportScreen.say(Catalog.aboutPrivacyPolicy))
		TutorialHarness.attach(self, name: "about-light", app: app)
		link.tap()
		TutorialHarness.wait(
			XCUIApplication(bundleIdentifier: "com.apple.mobilesafari"), until: .foreground)
		app.activate()
		TutorialHarness.wait(app, until: .foreground)
	}
}

@MainActor
private enum SupportScreen {
	static let phrasebook = CatalogPhrasebook(tag: .en)
	static let note = "The plan card skipped Tuesday."
	static let closeShareSheet = "Close"

	static var notSavingSentence: String {
		let display = DisplayLocale(
			preference: .automatic, preferredLanguages: ["en"],
			regionalConventions: Locale(identifier: "en_US"))
		let clock = FixedClock(now: "1998-06-15T08:00:00Z", timeZone: "Europe/Ljubljana")
		return phrasebook.say(
			Catalog.diagnosticsNotSaving, ["time": display.moment(clock.now, in: clock.timeZone)])
	}

	static func say(_ key: CatalogKey) -> String { phrasebook.say(key) }

	static func start(feedback: String? = nil) -> XCUIApplication {
		var arguments = FixtureArguments()
		arguments.feedback = feedback.flatMap(FixtureFeedbackScript.init(rawValue:))
		return start(arguments)
	}

	static func start(_ arguments: FixtureArguments) -> XCUIApplication {
		let app = XCUIApplication()
		TutorialHarness.launch(app, arguments: arguments)
		TutorialHarness.startUnconnected(app)
		TutorialHarness.openSettings(app)
		return app
	}

	static func startSharing() -> XCUIApplication {
		let app = start()
		open(app, "settings.diagnostics", showing: "diagnostics.make")
		TutorialHarness.named(app, "diagnostics.make").tap()
		TutorialHarness.wait(app.buttons[closeShareSheet], until: .hittable)
		return app
	}

	static func open(_ app: XCUIApplication, _ row: String, showing content: String) {
		let link = TutorialHarness.named(app, row)
		TutorialHarness.scroll(app, to: link)
		link.tap()
		TutorialHarness.wait(TutorialHarness.named(app, content))
	}

	static func outcome(_ app: XCUIApplication, _ identifier: String, _ sentence: String) {
		TutorialHarness.waitForIdentifier(app, identifier, reading: sentence)
	}

	static func shareAction(_ app: XCUIApplication, _ label: String) -> XCUIElement {
		let action = app.descendants(matching: .any).matching(
			NSPredicate(format: "label == %@", label)
		).firstMatch
		TutorialHarness.wait(action, until: .hittable)
		return action
	}

	static func tryAgain(_ app: XCUIApplication) {
		let button = TutorialHarness.named(app, "feedback.tryAgain")
		TutorialHarness.wait(button, until: .hittable)
		XCTAssertEqual(button.label, say(Catalog.chatTranscriptRetry))
		button.tap()
		outcome(app, "feedback.outcome", say(Catalog.feedbackReceived))
	}

	static func assertFeedbackCounts(_ app: XCUIApplication, requests: Int, stored: Int) {
		TutorialHarness.returnToChat(app)
		TutorialHarness.openDebug(app)
		XCTAssertEqual(
			TutorialHarness.debugRow(app, "fixture.feedbackRequests").label,
			"\(requests) feedback requests")
		XCTAssertEqual(
			TutorialHarness.debugRow(app, "fixture.feedbackStored").label,
			"\(stored) feedback notes stored")
		TutorialHarness.returnToChat(app)
	}
}
