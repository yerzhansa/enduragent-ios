import Foundation

struct Member {
	let name: String
	let value: OrderedJSON

	init(_ name: String, _ value: OrderedJSON) {
		self.name = name
		self.value = value
	}
}

enum OrderedJSON {
	case string(String)
	case integer(Int)
	case object([Member])

	func rendered(depth: Int = 0) -> String {
		switch self {
		case .string(let text):
			return OrderedJSON.quoted(text)
		case .integer(let value):
			return String(value)
		case .object(let members):
			guard !members.isEmpty else { return "{}" }
			let indent = String(repeating: "  ", count: depth + 1)
			let body = members.map { member in
				"\(indent)\(OrderedJSON.quoted(member.name)): \(member.value.rendered(depth: depth + 1))"
			}
			let closing = String(repeating: "  ", count: depth)
			return "{\n\(body.joined(separator: ",\n"))\n\(closing)}"
		}
	}

	static func quoted(_ text: String) -> String {
		var result = "\""
		for scalar in text.unicodeScalars {
			switch scalar {
			case "\"":
				result += "\\\""
			case "\\":
				result += "\\\\"
			case "\u{08}":
				result += "\\b"
			case "\u{0C}":
				result += "\\f"
			case "\n":
				result += "\\n"
			case "\r":
				result += "\\r"
			case "\t":
				result += "\\t"
			case _ where scalar.value < 0x20:
				result += String(format: "\\u%04x", scalar.value)
			default:
				result.unicodeScalars.append(scalar)
			}
		}
		return result + "\""
	}
}
