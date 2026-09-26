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

extension ULID: Comparable {}

public struct TurnID: Hashable, Sendable, Comparable {
	public let ulid: ULID

	package init(ulid: ULID) {
		self.ulid = ulid
	}

	public static func < (lhs: TurnID, rhs: TurnID) -> Bool {
		lhs.ulid < rhs.ulid
	}
}

public struct AttemptID: Hashable, Sendable {
	public let ulid: ULID

	package init(ulid: ULID) {
		self.ulid = ulid
	}
}

public struct DraftID: Hashable, Sendable {
	public let rawValue: UUID

	public init() {
		self.rawValue = UUID()
	}

	public init(rawValue: UUID) {
		self.rawValue = rawValue
	}
}

public struct Draft: Sendable, Equatable {
	public let id: DraftID
	public var text: String

	public init(id: DraftID, text: String) {
		self.id = id
		self.text = text
	}
}

public struct FlushJobID: Hashable, Sendable {
	public let ulid: ULID

	package init(ulid: ULID) {
		self.ulid = ulid
	}
}

public struct ResetID: Hashable, Sendable {
	public let ulid: ULID

	package init(ulid: ULID) {
		self.ulid = ulid
	}
}

public struct PreferenceChangeID: Hashable, Sendable {
	public let ulid: ULID

	package init(ulid: ULID) {
		self.ulid = ulid
	}
}

public struct CredentialChangeID: Hashable, Sendable {
	public let ulid: ULID

	package init(ulid: ULID) {
		self.ulid = ulid
	}
}

public struct LaunchID: Hashable, Sendable {
	public let ulid: ULID

	package init(ulid: ULID) {
		self.ulid = ulid
	}
}

public struct ChangeSetID: Hashable, Sendable {
	public let ulid: ULID

	package init(ulid: ULID) {
		self.ulid = ulid
	}
}

public struct ChangeSetRevision: Hashable, Sendable, Comparable {
	public let rawValue: Int

	package init(rawValue: Int) {
		self.rawValue = rawValue
	}

	public static func < (lhs: ChangeSetRevision, rhs: ChangeSetRevision) -> Bool {
		lhs.rawValue < rhs.rawValue
	}
}

public struct PlanningCommandID: Hashable, Sendable {
	public let rawValue: String

	package init(rawValue: String) {
		self.rawValue = rawValue
	}
}

public struct RefreshID: Hashable, Sendable {
	public let ulid: ULID

	package init(ulid: ULID) {
		self.ulid = ulid
	}
}

public struct DebugSampleID: Hashable, Sendable {
	public let ulid: ULID

	package init(ulid: ULID) {
		self.ulid = ulid
	}
}

public struct DeviceID: Hashable, Sendable, RawRepresentable {
	public let rawValue: String

	public init(rawValue: String) {
		self.rawValue = rawValue
	}

	public init() {
		self.rawValue = UUID().uuidString
	}
}

public struct ChatID: Hashable, Sendable, ExpressibleByStringLiteral {
	public let rawValue: String

	public init?(rawValue: String) {
		guard !rawValue.isEmpty, rawValue != "desktop", !rawValue.hasPrefix("plan:") else {
			return nil
		}
		self.rawValue = rawValue
	}

	public init(stringLiteral value: String) {
		guard let parsed = ChatID(rawValue: value) else {
			fatalError("invalid chat id")
		}
		self = parsed
	}

	public static let main: ChatID = "main"
}

public struct Nonce: Hashable, Sendable, RawRepresentable {
	public let rawValue: UUID

	public init(rawValue: UUID) {
		self.rawValue = rawValue
	}

	public init() {
		self.rawValue = UUID()
	}
}

public struct CivilDate: Hashable, Sendable, Comparable, ExpressibleByStringLiteral,
	CustomStringConvertible
{
	public let rawValue: String

	public init?(rawValue: String) {
		guard Self.isRealDateKey(rawValue) else { return nil }
		self.rawValue = rawValue
	}

	public init(stringLiteral value: String) {
		guard let parsed = CivilDate(rawValue: value) else {
			fatalError("invalid civil date")
		}
		self = parsed
	}

	public var description: String { rawValue }

	public static func < (lhs: CivilDate, rhs: CivilDate) -> Bool {
		lhs.rawValue < rhs.rawValue
	}

	public static func isRealDateKey(_ value: String) -> Bool {
		let formatter = DateFormatter()
		formatter.calendar = Calendar(identifier: .gregorian)
		formatter.locale = Locale(identifier: "en_US_POSIX")
		formatter.timeZone = TimeZone(secondsFromGMT: 0)
		formatter.dateFormat = "yyyy-MM-dd"
		formatter.isLenient = false
		return formatter.date(from: value) != nil
	}

	public init(date: Date, timeZone: TimeZone) {
		self.rawValue = GregorianStamp.day(date, timeZone: timeZone)
	}

	public init(year: Int, month: Int, day: Int) {
		self.rawValue = String(format: "%04d-%02d-%02d", year, month, day)
	}

	public func adding(days: Int) -> CivilDate {
		var calendar = Calendar(identifier: .gregorian)
		calendar.locale = Locale(identifier: "en_US_POSIX")
		calendar.timeZone = .gmt
		let parts = rawValue.split(separator: "-")
		let components = DateComponents(
			year: Int(parts[0]),
			month: Int(parts[1]),
			day: Int(parts[2])
		)
		guard
			let date = calendar.date(from: components),
			let shifted = calendar.date(byAdding: .day, value: days, to: date)
		else {
			fatalError("civil date \(rawValue) is not a real day")
		}
		return CivilDate(date: shifted, timeZone: .gmt)
	}
}

public struct DateKey: Hashable, Sendable, Comparable {
	public let rawValue: Int

	public init?(rawValue: Int) {
		guard rawValue >= 1000_01_01, rawValue <= 9999_12_31 else { return nil }
		self.rawValue = rawValue
	}

	public init(year: Int, month: Int, day: Int) {
		self.rawValue = year * 10_000 + month * 100 + day
	}

	public static func from(_ date: CivilDate) -> DateKey {
		let parts = date.rawValue.split(separator: "-")
		guard
			parts.count == 3,
			let year = Int(parts[0]),
			let month = Int(parts[1]),
			let day = Int(parts[2])
		else {
			fatalError("civil date \(date.rawValue) is not a date key")
		}
		return DateKey(year: year, month: month, day: day)
	}

	public var civil: CivilDate {
		CivilDate(year: rawValue / 10_000, month: (rawValue / 100) % 100, day: rawValue % 100)
	}

	public static func < (lhs: DateKey, rhs: DateKey) -> Bool {
		lhs.rawValue < rhs.rawValue
	}
}

public struct IANATimeZone: Hashable, Sendable {
	public let identifier: String

	public init?(identifier: String) {
		guard TimeZone(identifier: identifier) != nil else { return nil }
		self.identifier = identifier
	}

	public static let gmt: IANATimeZone = {
		guard let zone = IANATimeZone(identifier: "GMT") else {
			fatalError("IANA time zone GMT is invalid")
		}
		return zone
	}()

	public init(current timeZone: TimeZone) {
		self.identifier = timeZone.identifier
	}

	public var timeZone: TimeZone {
		TimeZone(identifier: identifier) ?? .gmt
	}
}

public enum SportID: String, Sendable {
	case cycling
}
