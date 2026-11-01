import SwiftUI

enum ChromePlacement {
	case pinned
	case inTranscript

	init(_ size: DynamicTypeSize) {
		self = size.isAccessibilitySize ? .inTranscript : .pinned
	}
}
