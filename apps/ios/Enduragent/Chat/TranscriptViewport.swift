import SwiftUI

struct TranscriptViewport: Equatable {
	var frame: CGRect

	func shows(_ card: CGRect) -> Bool {
		guard !frame.isNull, frame.height > 0, !card.isNull, card.height > 0 else { return false }
		let seen = card.intersection(frame)
		guard !seen.isNull else { return false }
		return seen.height >= min(card.height, frame.height) / 2
	}
}

extension EnvironmentValues {
	@Entry var transcriptViewport = TranscriptViewport(frame: .null)
}
