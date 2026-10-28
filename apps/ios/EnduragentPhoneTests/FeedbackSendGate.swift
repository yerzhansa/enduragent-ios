import XCTest

@MainActor
enum FeedbackSendGate {
	static func tapSend(in app: XCUIApplication) throws {
		let field = TutorialHarness.named(app, "feedback.field")
		let value = field.value as? String ?? ""
		guard FeedbackStepGuard.mayTapSend(fieldValue: value) else {
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
}
