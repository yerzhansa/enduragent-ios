import Foundation

extension JSONValue {
	package var objectFields: [String: JSONValue] {
		if case .object(let fields) = self { return fields }
		return [:]
	}

	package var arrayValue: [JSONValue]? {
		if case .array(let items) = self { return items }
		return nil
	}

	package var stringValue: String? {
		if case .string(let value) = self { return value }
		return nil
	}

	package var numberValue: Double? {
		if case .number(let value) = self { return value }
		return nil
	}

	package var boolValue: Bool? {
		if case .bool(let value) = self { return value }
		return nil
	}

	package func intValue() -> Int? {
		switch self {
		case .number(let value):
			return wholeInt(value)
		case .string(let value):
			return Int(value)
		default:
			return nil
		}
	}
}
