import Foundation

enum JavaScriptNumber {
	static func text(_ value: Double) -> String {
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

	static func fixed(_ value: Double, digits: Int) -> String {
		guard value.isFinite, value.magnitude < 1e21 else { return text(value) }
		let sign = value < 0 ? "-" : ""
		let magnitude = value.magnitude
		guard fractionBits(magnitude) == digits + 1 else {
			return sign + String(format: "%.\(digits)f", magnitude)
		}
		var exact = Array(String(format: "%.\(digits + 1)f", magnitude))
		exact.removeLast()
		if digits == 0 { exact.removeLast() }
		return sign + roundedUp(exact)
	}

	static func round(_ value: Double) -> Double {
		let floor = value.rounded(.down)
		let rounded = value - floor >= 0.5 ? floor + 1 : floor
		return rounded == 0 && value.sign == .minus ? -0.0 : rounded
	}

	static func roundToTenths(_ value: Double) -> Double {
		round(value * 10) / 10
	}

	static func json(_ value: Double) -> String {
		value.isFinite ? text(value) : "null"
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

	private static func fractionBits(_ magnitude: Double) -> Int {
		guard magnitude != 0 else { return 0 }
		return max(0, magnitude.significandWidth - Int(magnitude.exponent))
	}

	private static func roundedUp(_ truncated: [Character]) -> String {
		var characters = truncated
		var index = characters.count - 1
		while index >= 0 {
			guard let digit = characters[index].wholeNumberValue else {
				index -= 1
				continue
			}
			if digit < 9 {
				characters[index] = Character(String(digit + 1))
				return String(characters)
			}
			characters[index] = "0"
			index -= 1
		}
		return "1" + String(characters)
	}
}
