import Testing
import ToolSupport

struct FeedbackStepGuardTests {
	@Test(arguments: [
		"", " \n\t", "\u{0}", "a\u{0}b", String(repeating: "a", count: 4_001),
	])
	func aNoteTheAppMustRefuseMayBeSent(_ note: String) {
		#expect(FeedbackStepGuard.mayTapSend(fieldValue: note))
	}

	@Test(arguments: [
		"ab", "the lap table is cut off", String(repeating: "a", count: 4_000),
		" " + String(repeating: "a", count: 4_000) + " ",
	])
	func aNoteTheAppWouldDeliverIsNeverSent(_ note: String) {
		#expect(!FeedbackStepGuard.mayTapSend(fieldValue: note))
	}
}
