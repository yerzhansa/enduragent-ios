import XCTest

@MainActor
enum FeedbackSendGate {
	static func tapSend(in app: XCUIApplication) throws {
		let field = TutorialHarness.named(app, "feedback.field")
		guard FeedbackStepGuard.mayTapSend(fieldValue: try note(in: field)) else {
			throw PhoneRunBlocked(reason: "fail send-guard")
		}
		let send = TutorialHarness.named(app, "feedback.send")
		let prompt = TutorialHarness.named(app, "feedback.prompt")
		for _ in 0..<3 where !send.isHittable {
			prompt.swipeUp()
		}
		guard send.isHittable else {
			throw PhoneRunBlocked(reason: "Send cannot be reached above the keyboard.")
		}
		send.tap()
	}

	static func readsEmpty(_ field: XCUIElement) -> Bool {
		guard let shown = field.value as? String else { return true }
		return shown.isEmpty || shown == field.placeholderValue
	}

	private static func note(in field: XCUIElement) throws -> String {
		let shown = field.value as? String
		if let shown, shown.isEmpty || shown != field.placeholderValue { return shown }
		let probe = "x"
		field.tap()
		field.typeText(probe)
		guard field.value as? String == probe else {
			throw PhoneRunBlocked(reason: "fail send-guard")
		}
		field.typeText(XCUIKeyboardKey.delete.rawValue)
		guard
			TutorialHarness.wait(
				until: { readsEmpty(field) }, required: false,
				message: "The probe stayed in the note.")
		else {
			throw PhoneRunBlocked(reason: "fail send-guard")
		}
		return ""
	}
}
