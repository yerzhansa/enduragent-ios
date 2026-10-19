import EnduragentCoach
import XCTest

extension ReviewAccessibility {
	static func disclaimerOnOpening(_ test: XCTestCase, _ language: LanguageTag) {
		let arguments = FixtureArguments()
		let run = MatrixRun.begin(test, language, arguments: arguments)
		reopenAtLargestText(run.app, arguments)
		let label = run.say(Catalog.chatViewDisclaimer)
		let reading = NSPredicate(format: "label == %@", label)
		let disclaimer = run.named("chat.transcript").staticTexts.matching(reading).firstMatch
		TutorialHarness.wait(run.named("chat.welcome"), within: .turn)
		TutorialHarness.wait(
			until: {
				let band = TutorialHarness.transcriptBand(run.app)
				let frame = disclaimer.frame
				return disclaimer.exists && frame.minY >= band.minY && frame.maxY <= band.maxY
			},
			message:
				"[\(language.rawValue)] at the largest text size the chat did not open with the disclaimer whole on screen"
		)
		XCTAssertEqual(
			run.named("chat.composer.container").staticTexts.matching(reading).count, 0,
			"[\(language.rawValue)] at the largest text size the disclaimer is still under the composer"
		)
		do {
			try run.app.performAccessibilityAudit(for: [.textClipped]) { issue in
				guard let element = issue.element, element.exists else { return true }
				return element.label != label
			}
		} catch {
			XCTFail("[\(language.rawValue)] the accessibility audit did not run: \(error)")
		}
		TutorialHarness.attach(
			test, name: "u9-2-\(language.rawValue)-disclaimer-open", app: run.app)
	}
}
