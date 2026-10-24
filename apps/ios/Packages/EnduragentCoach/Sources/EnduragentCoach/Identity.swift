import Foundation

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

package struct ProcessID: Hashable, Sendable {
	package let ulid: ULID

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

package struct FlushJobID: Hashable, Sendable {
	package let ulid: ULID

	package init(ulid: ULID) {
		self.ulid = ulid
	}
}

public struct ResetID: Hashable, Sendable {
	package let ulid: ULID

	package init(ulid: ULID) {
		self.ulid = ulid
	}
}

package struct PreferenceChangeID: Hashable, Sendable {
	package let ulid: ULID

	package init(ulid: ULID) {
		self.ulid = ulid
	}
}

package struct CredentialChangeID: Hashable, Sendable {
	package let ulid: ULID

	package init(ulid: ULID) {
		self.ulid = ulid
	}
}

package struct LaunchID: Hashable, Sendable {
	package let ulid: ULID

	package init(ulid: ULID) {
		self.ulid = ulid
	}
}

public struct WorkoutReviewID: Hashable, Sendable {
	public let ulid: ULID

	package init(ulid: ULID) {
		self.ulid = ulid
	}
}

public struct ReviewRevision: Hashable, Sendable, Comparable {
	public let rawValue: Int

	package init(rawValue: Int) {
		self.rawValue = rawValue
	}

	public static func < (lhs: ReviewRevision, rhs: ReviewRevision) -> Bool {
		lhs.rawValue < rhs.rawValue
	}

	package var next: ReviewRevision {
		ReviewRevision(rawValue: rawValue + 1)
	}
}

package struct ClaimID: Hashable, Sendable {
	package let ulid: ULID

	package init(ulid: ULID) {
		self.ulid = ulid
	}
}

package struct DraftKey: Hashable, Sendable {
	package let turn: TurnID
	package let attempt: AttemptID

	package init(turn: TurnID, attempt: AttemptID) {
		self.turn = turn
		self.attempt = attempt
	}
}

package struct DebugSampleID: Hashable, Sendable {
	package let ulid: ULID

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

package struct Nonce: Hashable, Sendable, RawRepresentable {
	package let rawValue: UUID

	package init(rawValue: UUID) {
		self.rawValue = rawValue
	}

	package init() {
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
		guard value.utf8.count == 10 else { return false }
		let bytes = Array(value.utf8)
		guard bytes[4] == UInt8(ascii: "-"), bytes[7] == UInt8(ascii: "-"),
			bytes.enumerated().allSatisfy({ index, byte in
				index == 4 || index == 7 || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
			})
		else { return false }
		let year = bytes.prefix(4).reduce(0) { $0 * 10 + Int($1 - UInt8(ascii: "0")) }
		let month = Int(bytes[5] - UInt8(ascii: "0")) * 10 + Int(bytes[6] - UInt8(ascii: "0"))
		let day = Int(bytes[8] - UInt8(ascii: "0")) * 10 + Int(bytes[9] - UInt8(ascii: "0"))
		guard (1...12).contains(month) else { return false }
		let daysInMonth: Int
		switch month {
		case 2:
			let leapYear = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
			daysInMonth = leapYear ? 29 : 28
		case 4, 6, 9, 11:
			daysInMonth = 30
		default:
			daysInMonth = 31
		}
		return (1...daysInMonth).contains(day)
	}

	public init(date: Date, timeZone: TimeZone) {
		self.rawValue = GregorianStamp.day(date, timeZone: timeZone)
	}

	public init(year: Int, month: Int, day: Int) {
		self.rawValue = String(format: "%04d-%02d-%02d", year, month, day)
	}

	public func adding(days: Int) -> CivilDate {
		let (year, month, day) = Self.civil(fromDayNumber: dayNumber &+ days)
		return CivilDate(year: year, month: month, day: day)
	}

	func days(until other: CivilDate) -> Int {
		other.dayNumber - dayNumber
	}

	var weekday: Weekday {
		Weekday.allCases[(dayNumber % 7 + 10) % 7]
	}

	private var dayNumber: Int {
		let parts = rawValue.split(separator: "-", omittingEmptySubsequences: false)
		guard parts.count >= 3,
			let year = Int(parts.dropLast(2).joined(separator: "-")),
			let month = Int(parts[parts.count - 2]),
			let day = Int(parts[parts.count - 1])
		else {
			fatalError("civil date \(rawValue) is not a day")
		}
		let marchYear = month > 2 ? year : year - 1
		let era = (marchYear >= 0 ? marchYear : marchYear - 399) / 400
		let yearOfEra = marchYear - era * 400
		let dayOfYear = (153 * (month > 2 ? month - 3 : month + 9) + 2) / 5 + day - 1
		let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
		return era * 146_097 + dayOfEra - 719_468
	}

	private static func civil(fromDayNumber dayNumber: Int) -> (year: Int, month: Int, day: Int) {
		let fromMarchZero = dayNumber &+ 719_468
		let era = (fromMarchZero >= 0 ? fromMarchZero : fromMarchZero &- 146_096) / 146_097
		let dayOfEra = fromMarchZero &- era &* 146_097
		let yearOfEra =
			(dayOfEra - dayOfEra / 1_460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
		let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
		let monthFromMarch = (5 * dayOfYear + 2) / 153
		let day = dayOfYear - (153 * monthFromMarch + 2) / 5 + 1
		let month = monthFromMarch < 10 ? monthFromMarch + 3 : monthFromMarch - 9
		let year = yearOfEra &+ era &* 400 &+ (month <= 2 ? 1 : 0)
		return (year, month, day)
	}
}

enum Weekday: String, Sendable, CaseIterable {
	case mon, tue, wed, thu, fri, sat, sun
}

public struct DateKey: Hashable, Sendable, Comparable {
	public let rawValue: Int

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

package struct IANATimeZone: Hashable, Sendable {
	package let identifier: String

	package init?(identifier: String) {
		guard TimeZone(identifier: identifier) != nil else { return nil }
		self.identifier = identifier
	}

	package static let gmt: IANATimeZone = {
		guard let zone = IANATimeZone(identifier: "GMT") else {
			fatalError("IANA time zone GMT is invalid")
		}
		return zone
	}()

	package init(current timeZone: TimeZone) {
		self.identifier = timeZone.identifier
	}

	package var timeZone: TimeZone {
		TimeZone(identifier: identifier) ?? .gmt
	}
}

public enum SportID: String, Sendable {
	case cycling
}
