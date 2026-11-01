import EnduragentCoach
import EnduragentCoachFixtures
import XCTest

extension LanguageMatrix {
	static func support(_ test: XCTestCase, _ language: LanguageTag) {
		var arguments = FixtureArguments(onboarded: true)
		arguments.feedback = FixtureFeedbackScript(rawValue: "offline,offline,lost,lost,204")
		let run = MatrixRun.begin(test, language, arguments: arguments)
		let app = run.app
		run.readSupportSection()
		run.readFeedback()
		let field = run.named("feedback.field")
		field.tap()
		field.typeText(SupportScreen.note)
		TutorialHarness.wait(field, until: .value(SupportScreen.note))
		SupportScreen.button(app, "feedback.send").tap()
		run.expectFeedback(Catalog.feedbackNotSentNoConnection, "feedback-not-sent")
		run.tryFeedbackAgain()
		run.expectFeedback(Catalog.feedbackNotConfirmed, "feedback-not-confirmed")
		run.tryFeedbackAgain()
		run.expectFeedback(Catalog.feedbackReceived, "feedback-received")
		SupportScreen.button(app, "feedback.send").tap()
		run.expectFeedback(Catalog.feedbackRefusedEmpty, "feedback-refused-empty")
		run.readDiagnostics()
		run.tap("diagnostics.make")
		let close = app.buttons[SupportScreen.closeShareSheet]
		TutorialHarness.wait(close, until: .hittable)
		close.tap()
		run.expect("diagnostics.outcome", Catalog.diagnosticsCanceled)
		TutorialHarness.wait(run.named("diagnostics.make"), until: .enabled)
		run.screen("diagnostics-canceled")
		run.readAbout()
		SupportScreen.assertFeedbackCounts(app, requests: 5, stored: 1)
	}
}

extension MatrixRun {
	func readSupport() {
		readSupportSection()
		readFeedback()
		readDiagnostics()
		readAbout()
	}

	func readSupportSection() {
		TutorialHarness.returnToChat(app)
		TutorialHarness.openSettings(app)
		TutorialHarness.scroll(app, to: named("settings.about"))
		expectText(Catalog.settingsSupportTitle)
		expect("settings.feedback", Catalog.feedbackTitle)
		expect("settings.diagnostics", Catalog.diagnosticsTitle)
		expect("settings.about", Catalog.aboutTitle)
		screen("support-section")
	}

	func readFeedback() {
		openSupport("settings.feedback", showing: "feedback.field")
		expectTitle(Catalog.feedbackTitle)
		expect("feedback.prompt", Catalog.feedbackPrompt)
		expect("feedback.send", Catalog.feedbackSend)
		screen("feedback")
	}

	func readDiagnostics() {
		openSupport("settings.diagnostics", showing: "diagnostics.make")
		expectTitle(Catalog.diagnosticsTitle)
		expect("diagnostics.explanation", Catalog.diagnosticsExplanation)
		expect("diagnostics.make", Catalog.diagnosticsMake)
		screen("diagnostics")
	}

	func readAbout() {
		openSupport("settings.about", showing: "about.value.version")
		expectTitle(Catalog.aboutTitle)
		SupportScreen.outcome(app, "about.value.name", "Enduragent")
		expect("about.version", Catalog.aboutVersion)
		expect("about.privacyPolicy", Catalog.aboutPrivacyPolicy)
		screen("about")
	}

	fileprivate func expectFeedback(_ sentence: CatalogKey, _ name: String) {
		expect("feedback.outcome", sentence)
		screen(name)
	}

	fileprivate func tryFeedbackAgain() {
		expect("feedback.tryAgain", Catalog.chatTranscriptRetry)
		SupportScreen.button(app, "feedback.tryAgain").tap()
	}

	private func openSupport(_ row: String, showing content: String) {
		TutorialHarness.returnToChat(app)
		TutorialHarness.openSettings(app)
		SupportScreen.open(app, row, showing: content)
	}
}
