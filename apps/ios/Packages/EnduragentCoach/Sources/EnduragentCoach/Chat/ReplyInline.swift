import Foundation

public enum InlineStyle: Sendable, Hashable {
	case bold
	case italic
	case strikethrough
	case inlineCode
}

public struct StyledText: Sendable, Equatable {
	public let text: String
	public let styles: Set<InlineStyle>

	public init(text: String, styles: Set<InlineStyle>) {
		self.text = text
		self.styles = styles
	}
}

public enum ReplyRun: Sendable, Equatable {
	case text(StyledText)
	case link(label: [StyledText], target: HTTPLink)
	case literal(String)

	public var accessibilityText: String {
		switch self {
		case .text(let text): return text.text
		case .link(let label, _): return label.map(\.text).joined()
		case .literal(let source): return source
		}
	}
}

public struct HTTPLink: Sendable, Equatable {
	public let url: URL

	init?(validating url: URL) {
		guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
			let host = url.host, !host.isEmpty
		else { return nil }
		self.url = url
	}
}
