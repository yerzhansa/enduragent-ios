import Foundation

public enum CatalogArgument: Sendable, Equatable, ExpressibleByStringLiteral {
	case text(String)
	case integer(Int)
	case decimal(Double, DisplayPrecision)
	case day(CivilDate)

	package var canonicalText: String {
		switch self {
		case .text(let text): text
		case .integer(let value): String(value)
		case .decimal(let value, _): String(value)
		case .day(let day): day.rawValue
		}
	}

	public init(stringLiteral value: String) {
		self = .text(value)
	}
}

public enum DisplayDateStyle: Sendable, Equatable {
	case numeric
	case named
}

public enum DisplayPrecision: Sendable, Equatable {
	case whole
	case tenths
	case compact
}
