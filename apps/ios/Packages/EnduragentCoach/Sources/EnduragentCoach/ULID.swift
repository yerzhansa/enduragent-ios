import Foundation

public struct ULID: Hashable, Sendable, RawRepresentable {
	public let rawValue: String

	public init?(rawValue: String) {
		let alphabet = CharacterSet(charactersIn: "0123456789ABCDEFGHJKMNPQRSTVWXYZ")
		guard rawValue.count == 26, rawValue.unicodeScalars.allSatisfy({ alphabet.contains($0) })
		else {
			return nil
		}
		self.rawValue = rawValue
	}

	public static func generate(at now: Date) -> ULID {
		let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
		let ms = max(0, (now.timeIntervalSince1970 * 1000).rounded(.down))
		var time = UInt64(ms)
		var chars = [Character](repeating: "0", count: 26)
		for index in (0..<10).reversed() {
			chars[index] = alphabet[Int(time % 32)]
			time /= 32
		}
		var rng = SystemRandomNumberGenerator()
		for index in 10..<26 {
			chars[index] = alphabet[Int(rng.next() % 32)]
		}
		return ULID(characters: chars)
	}

	public static func < (lhs: ULID, rhs: ULID) -> Bool {
		lhs.rawValue < rhs.rawValue
	}

	package var time: Date {
		let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
		let ms = rawValue.prefix(10).reduce(UInt64(0)) { total, character in
			guard let digit = alphabet.firstIndex(of: character) else {
				preconditionFailure("ULID init admits only Crockford base32 characters")
			}
			return total * 32 + UInt64(digit)
		}
		return Date(timeIntervalSince1970: Double(ms) / 1000)
	}

	package func incremented() -> ULID {
		let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
		var chars = Array(rawValue)
		for index in (0..<26).reversed() {
			guard let position = alphabet.firstIndex(of: chars[index]) else {
				continue
			}
			if position + 1 < alphabet.count {
				chars[index] = alphabet[position + 1]
				return ULID(characters: chars)
			}
			chars[index] = alphabet[0]
		}
		return ULID(characters: chars)
	}

	private init(characters: [Character]) {
		self.rawValue = String(characters)
	}
}
