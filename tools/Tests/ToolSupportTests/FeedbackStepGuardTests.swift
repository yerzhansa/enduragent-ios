import Testing
import ToolSupport

struct FeedbackStepGuardTests {
	static let javaScriptWhitespace: [Unicode.Scalar] = [
		"\u{0009}", "\u{000A}", "\u{000B}", "\u{000C}", "\u{000D}", "\u{0020}", "\u{00A0}",
		"\u{1680}", "\u{2000}", "\u{2001}", "\u{2002}", "\u{2003}", "\u{2004}", "\u{2005}",
		"\u{2006}", "\u{2007}", "\u{2008}", "\u{2009}", "\u{200A}", "\u{2028}", "\u{2029}",
		"\u{202F}", "\u{205F}", "\u{3000}", "\u{FEFF}",
	]
	static let keptByTheApp: [Unicode.Scalar] = [
		"\u{001C}", "\u{001F}", "\u{0085}", "\u{180E}", "\u{200B}", "\u{200C}", "\u{200D}",
		"\u{2060}",
	]
	static let atTheLimit = String(repeating: "a", count: FeedbackStepGuard.limit)

	@Test(arguments: [
		"", " \n\t", "\u{0}", "a\u{0}b", " \u{0} ", String(repeating: "a", count: 4_001),
		String(repeating: "a", count: 2_000) + " " + String(repeating: "a", count: 2_000),
	])
	func aNoteTheAppMustRefuseMayBeSent(_ note: String) {
		#expect(FeedbackStepGuard.mayTapSend(fieldValue: note))
	}

	@Test(arguments: [
		"ab", "the lap table is cut off", atTheLimit, " " + atTheLimit + " ", "\u{0085}",
		"\u{200B}", "\u{FEFF}\u{FEFF}" + String(repeating: "a", count: 3_999),
	])
	func aNoteTheAppWouldDeliverIsNeverSent(_ note: String) {
		#expect(!FeedbackStepGuard.mayTapSend(fieldValue: note))
	}

	@Test(arguments: javaScriptWhitespace)
	func aScalarTheAppTrimsIsTrimmed(_ scalar: Unicode.Scalar) {
		let space = String(scalar)
		#expect(FeedbackStepGuard.mayTapSend(fieldValue: space))
		#expect(!FeedbackStepGuard.mayTapSend(fieldValue: space + Self.atTheLimit + space))
	}

	@Test(arguments: keptByTheApp)
	func aScalarTheAppKeepsIsCounted(_ scalar: Unicode.Scalar) {
		let kept = String(scalar)
		#expect(!FeedbackStepGuard.mayTapSend(fieldValue: kept))
		#expect(FeedbackStepGuard.mayTapSend(fieldValue: kept + Self.atTheLimit))
	}
}
