import Foundation

public enum FeedbackStepGuard {
	public static let limit = 4_000

	public static func mayTapSend(fieldValue: String) -> Bool {
		let kept = fieldValue.unicodeScalars.filter {
			!CharacterSet.whitespacesAndNewlines.contains($0)
		}
		let stripped = String(String.UnicodeScalarView(kept))
		return stripped.isEmpty || fieldValue.unicodeScalars.contains("\u{0}")
			|| stripped.utf16.count > limit
	}
}
