public enum FeedbackStepGuard {
	public static let limit = 4_000
	private static let javaScriptWhitespace: Set<Unicode.Scalar> = [
		"\u{0009}", "\u{000A}", "\u{000B}", "\u{000C}", "\u{000D}", "\u{0020}", "\u{00A0}",
		"\u{1680}", "\u{2000}", "\u{2001}", "\u{2002}", "\u{2003}", "\u{2004}", "\u{2005}",
		"\u{2006}", "\u{2007}", "\u{2008}", "\u{2009}", "\u{200A}", "\u{2028}", "\u{2029}",
		"\u{202F}", "\u{205F}", "\u{3000}", "\u{FEFF}",
	]

	public static func mayTapSend(fieldValue: String) -> Bool {
		let scalars = fieldValue.unicodeScalars
		guard let first = scalars.firstIndex(where: { !javaScriptWhitespace.contains($0) }),
			let last = scalars.lastIndex(where: { !javaScriptWhitespace.contains($0) })
		else { return true }
		let trimmed = String(String.UnicodeScalarView(scalars[first...last]))
		return trimmed.unicodeScalars.contains("\u{0}") || trimmed.utf16.count > limit
	}
}
