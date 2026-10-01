import EnduragentCoach
import UIKit
import XCTest

@MainActor
final class ComposerIconButtonsProof: XCTestCase {
	func testEnglishComposerFitsWhileWorking() {
		ComposerIconButtonsScreen.prove(self, language: .en, dark: false)
	}

	func testBrazilianPortugueseComposerFitsWhileWorking() {
		ComposerIconButtonsScreen.prove(self, language: .ptBR, dark: false)
	}
}

@MainActor
final class ComposerIconButtonsDarkProof: XCTestCase {
	func testEnglishComposerFitsWhileWorking() {
		ComposerIconButtonsScreen.prove(self, language: .en, dark: true)
	}

	func testBrazilianPortugueseComposerFitsWhileWorking() {
		ComposerIconButtonsScreen.prove(self, language: .ptBR, dark: true)
	}
}

@MainActor
private enum ComposerIconButtonsScreen {
	static func prove(_ test: XCTestCase, language: LanguageTag, dark: Bool) {
		let app = XCUIApplication()
		TutorialHarness.launch(
			app, language: language.rawValue, locale: language == .ptBR ? "pt_BR" : "en_US")
		TutorialHarness.completeOnboarding(app, language: language)
		XCTAssertEqual(app.frame.width, 390, accuracy: 1, "run on a 390 pt wide iPhone")
		TutorialHarness.send(app, "fixture:text-then-hang")
		TutorialHarness.waitForLabel(app, "This week has Tuesday sweet spot")
		TutorialHarness.wait(app.keyboards.firstMatch, until: .absent)
		let input = TutorialHarness.named(app, "chat.composer")
		let stop = TutorialHarness.named(app, "chat.stop")
		let send = TutorialHarness.named(app, "chat.send")
		for control in [input, stop, send] {
			TutorialHarness.wait(control, until: .hittable)
		}
		TutorialHarness.wait(stop, until: .enabled)
		TutorialHarness.wait(send, until: .enabled)
		let phrasebook = CatalogPhrasebook(tag: language)
		let placeholder = phrasebook.say(Catalog.chatComposerMessagePlaceholder)
		XCTAssertEqual(input.placeholderValue, placeholder)
		XCTAssertEqual(input.value as? String, placeholder)
		XCTAssertEqual(stop.label, phrasebook.say(Catalog.chatComposerStop))
		XCTAssertEqual(send.label, phrasebook.say(Catalog.chatComposerSend))
		let font = UIFont.preferredFont(forTextStyle: .body)
		let placeholderWidth = (placeholder as NSString).size(withAttributes: [.font: font]).width
		XCTAssertGreaterThanOrEqual(
			input.frame.width, ceil(placeholderWidth), "the complete placeholder must fit")
		let composerFrame = TutorialHarness.named(app, "chat.composer.container").frame
		let frames = [input.frame, stop.frame, send.frame]
		for frame in frames {
			XCTAssertFalse(frame.isEmpty)
			XCTAssertTrue(composerFrame.contains(frame))
			XCTAssertTrue(app.frame.contains(frame))
			XCTAssertLessThanOrEqual(frame.height, ceil(font.lineHeight) + 1)
			XCTAssertEqual(frame.midY, input.frame.midY, accuracy: 1)
		}
		XCTAssertLessThanOrEqual(input.frame.maxX, stop.frame.minX)
		XCTAssertLessThanOrEqual(stop.frame.maxX, send.frame.minX)
		for button in [stop, send] {
			XCTAssertEqual(button.elementType, .button)
			TutorialHarness.assertIconButtonWidth(button)
			XCTAssertEqual(button.staticTexts.count, 0, "the button title must not be drawn")
		}
		TutorialHarness.attach(
			test, name: "composer-icons-\(language.rawValue)-\(dark ? "dark" : "light")", app: app)
		let luminance = TutorialHarness.meanLuminance(app.screenshot())
		if dark {
			XCTAssertLessThan(luminance, 0.4, "the capture is not in dark appearance")
		} else {
			XCTAssertGreaterThan(luminance, 0.4, "the capture is not in light appearance")
		}
		stop.tap()
		TutorialHarness.wait(stop, until: .absent)
		TutorialHarness.wait(TutorialHarness.named(app, "chat.working"), until: .absent)
		TutorialHarness.assertZeroFixtureRequests(app)
	}
}
