import Foundation

extension String {
	public var quotedAsJSON: String {
		var result = "\""
		for scalar in unicodeScalars {
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
				let hex = String(scalar.value, radix: 16)
				result += "\\u" + String(repeating: "0", count: 4 - hex.count) + hex
			default:
				result.unicodeScalars.append(scalar)
			}
		}
		return result + "\""
	}
}

public enum JavaScriptNumber {
	public static func text(_ value: Double) -> String {
		guard value.isFinite else {
			return value.isNaN ? "NaN" : value < 0 ? "-Infinity" : "Infinity"
		}
		guard value != 0 else { return "0" }
		let (digits, pointPosition) = shortestDigits(value.magnitude)
		let sign = value < 0 ? "-" : ""
		let count = digits.count
		if count <= pointPosition, pointPosition <= 21 {
			return sign + digits + String(repeating: "0", count: pointPosition - count)
		}
		if pointPosition > 0, pointPosition <= 21 {
			return sign + digits.prefix(pointPosition) + "." + digits.dropFirst(pointPosition)
		}
		if pointPosition > -6, pointPosition <= 0 {
			return sign + "0." + String(repeating: "0", count: -pointPosition) + digits
		}
		let exponent = pointPosition - 1
		let fraction = count == 1 ? "" : "." + digits.dropFirst()
		return sign + digits.prefix(1) + fraction + "e" + (exponent < 0 ? "-" : "+")
			+ String(exponent.magnitude)
	}

	public static func fixedToOneDecimal(_ value: Double) -> String {
		guard value.isFinite, value.magnitude < 1e21 else { return text(value) }
		let quarters = value * 4
		guard quarters == quarters.rounded(), quarters.magnitude < 1e15,
			Int64(quarters.magnitude) % 2 == 1
		else {
			return String(format: "%.1f", value)
		}
		let tenths = Int64((value.magnitude * 10).rounded(.up))
		return "\(value < 0 ? "-" : "")\(tenths / 10).\(tenths % 10)"
	}

	public static func parse(_ text: String) -> Double {
		let trimmed = text.trimmedAsJavaScript
		if trimmed.isEmpty { return 0 }
		for (prefix, radix) in [("0x", 16), ("0X", 16), ("0o", 8), ("0O", 8), ("0b", 2), ("0B", 2)]
		where trimmed.hasUnitPrefix(prefix) {
			let digits = trimmed.dropFirst(2)
			guard !digits.isEmpty,
				digits.allSatisfy({ $0.isASCII && $0.hexDigitValue ?? radix < radix })
			else { return .nan }
			return digits.reduce(0) { $0 * Double(radix) + Double($1.hexDigitValue ?? 0) }
		}
		var unsigned = Substring(trimmed)
		var sign = 1.0
		if let first = unsigned.first, first == "+" || first == "-" {
			sign = first == "-" ? -1 : 1
			unsigned = unsigned.dropFirst()
		}
		if unsigned == "Infinity" { return sign * .infinity }
		var scanner = DecimalLiteral(units: Array(unsigned.utf8))
		guard scanner.isWhole, let number = Double(String(unsigned)) else { return .nan }
		return sign * number
	}

	private static func shortestDigits(_ magnitude: Double) -> (digits: String, pointPosition: Int)
	{
		let described = "\(magnitude)"
		let parts = described.split(separator: "e", maxSplits: 1)
		let exponent = parts.count == 2 ? Int(parts[1]) ?? 0 : 0
		let mantissa = parts[0].split(
			separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
		let whole = String(mantissa[0])
		let fraction = mantissa.count == 2 ? String(mantissa[1]) : ""
		var digits = whole + fraction
		var pointPosition = whole.count + exponent
		let leadingZeros = digits.prefix { $0 == "0" }.count
		digits.removeFirst(leadingZeros)
		pointPosition -= leadingZeros
		while digits.count > 1, digits.last == "0" {
			digits.removeLast()
		}
		return (digits, pointPosition)
	}

	private struct DecimalLiteral {
		let units: [UInt8]
		private var position = 0

		init(units: [UInt8]) {
			self.units = units
		}

		var isWhole: Bool {
			mutating get {
				let whole = digits()
				var fraction = 0
				if next == UInt8(ascii: ".") {
					position += 1
					fraction = digits()
				}
				guard whole + fraction > 0 else { return false }
				if next == UInt8(ascii: "e") || next == UInt8(ascii: "E") {
					position += 1
					if next == UInt8(ascii: "+") || next == UInt8(ascii: "-") { position += 1 }
					guard digits() > 0 else { return false }
				}
				return position == units.count
			}
		}

		private var next: UInt8? {
			position < units.count ? units[position] : nil
		}

		private mutating func digits() -> Int {
			let start = position
			while let unit = next, unit >= UInt8(ascii: "0"), unit <= UInt8(ascii: "9") {
				position += 1
			}
			return position - start
		}
	}
}

extension String {
	private static let javaScriptWhitespace: Set<UInt32> = Set(
		[
			0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x20, 0xA0, 0x1680, 0x2028, 0x2029, 0x202F, 0x205F,
			0x3000, 0xFEFF,
		]
			+ Array(0x2000...0x200A))

	public var trimmedAsJavaScript: String {
		String(
			String.UnicodeScalarView(
				trimmedEndScalars.drop { Self.javaScriptWhitespace.contains($0.value) }))
	}

	public var trimmedEndAsJavaScript: String {
		String(String.UnicodeScalarView(trimmedEndScalars))
	}

	private var trimmedEndScalars: [Unicode.Scalar] {
		var scalars = Array(unicodeScalars)
		while let last = scalars.last, Self.javaScriptWhitespace.contains(last.value) {
			scalars.removeLast()
		}
		return scalars
	}

	public func isOrdered(before other: String) -> Bool {
		utf16.lexicographicallyPrecedes(other.utf16)
	}

	public func localeCompare(_ other: String) -> ComparisonResult {
		compare(other, options: [], range: nil, locale: Locale(identifier: "en"))
	}
}

extension JSONValue {
	public var string: String? {
		guard case .string(let value) = self else { return nil }
		return value
	}

	public var number: Double? {
		guard case .number(let value) = self else { return nil }
		return value
	}

	public var interpolated: String {
		switch self {
		case .undefined:
			"undefined"
		case .null:
			"null"
		case .bool(let value):
			value ? "true" : "false"
		case .number(let value):
			JavaScriptNumber.text(value)
		case .string(let value):
			value
		case .array(let elements):
			elements.map { element in
				switch element {
				case .undefined, .null: ""
				default: element.interpolated
				}
			}.joined(separator: ",")
		case .object:
			"[object Object]"
		}
	}

	public var compactText: String {
		text(indent: nil, depth: 0) ?? "null"
	}

	public var indentedText: String {
		text(indent: "  ", depth: 0) ?? "null"
	}

	public static func keyed(_ members: KeyValuePairs<String, JSONValue>) -> JSONValue {
		.object(members.map { JSONMember(key: $0.key, value: $0.value) })
	}

	private func text(indent: String?, depth: Int) -> String? {
		switch self {
		case .undefined:
			return nil
		case .null:
			return "null"
		case .bool(let value):
			return value ? "true" : "false"
		case .number(let value):
			return value.isFinite ? JavaScriptNumber.text(value) : "null"
		case .string(let value):
			return value.quotedAsJSON
		case .array(let elements):
			return Self.wrap(
				elements.map { $0.text(indent: indent, depth: depth + 1) ?? "null" },
				open: "[", close: "]", indent: indent, depth: depth)
		case .object(let members):
			let separator = indent == nil ? ":" : ": "
			return Self.wrap(
				members.compactMap { member in
					member.value.text(indent: indent, depth: depth + 1).map {
						member.key.quotedAsJSON + separator + $0
					}
				}, open: "{", close: "}", indent: indent, depth: depth)
		}
	}

	private static func wrap(
		_ items: [String], open: String, close: String, indent: String?, depth: Int
	) -> String {
		guard !items.isEmpty else { return open + close }
		guard let indent else { return open + items.joined(separator: ",") + close }
		let inner = String(repeating: indent, count: depth + 1)
		let outer = String(repeating: indent, count: depth)
		return open + "\n" + inner + items.joined(separator: ",\n" + inner) + "\n" + outer + close
	}
}
