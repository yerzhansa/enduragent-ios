import Foundation

package protocol TrainingReads: Sendable {
	func profile() async throws -> AthleteProfile
	func wellness(in range: ReadRange) async throws -> [WellnessDay]
	func activities(in range: ReadRange) async throws -> ActivityListing
	func activity(_ id: ActivityID) async throws -> ActivityDetailRead
	func streams(of id: ActivityID, channels: StreamChannels) async throws -> StreamSummary
}

package typealias TrainingClient = TrainingReads & IntervalsClient

package struct ReadRange: Sendable, Equatable {
	package let oldest: CivilDate
	package let newest: CivilDate

	package init(oldest: CivilDate, newest: CivilDate?, today: CivilDate) throws(ReadRangeRefusal) {
		let newest = newest ?? today
		if oldest > newest { throw .reversed(oldest: oldest, newest: newest) }
		let days = IntervalsPolicy.inclusiveDayCount(from: oldest, to: newest)
		if days > IntervalsPolicy.listMaxRangeDays { throw .tooWide(days: days) }
		self.oldest = oldest
		self.newest = newest
	}

	private init(endingOn today: CivilDate, lookback days: Int) {
		self.oldest = today.adding(days: -(days - 1))
		self.newest = today
	}

	package static func snapshotLookback(endingOn today: CivilDate) -> ReadRange {
		ReadRange(endingOn: today, lookback: 7)
	}

	package static func day(_ date: CivilDate) -> ReadRange {
		ReadRange(endingOn: date, lookback: 1)
	}

	package static func addWindow(around date: CivilDate) -> ReadRange {
		ReadRange(
			endingOn: date.adding(days: IntervalsPolicy.listMaxRangeDays / 2 - 1),
			lookback: IntervalsPolicy.listMaxRangeDays)
	}

	package func contains(_ date: CivilDate) -> Bool {
		date >= oldest && date <= newest
	}
}

package enum ReadRangeRefusal: Error, Equatable {
	case reversed(oldest: CivilDate, newest: CivilDate)
	case tooWide(days: Int)
}

package struct StreamChannels: Sendable, Equatable {
	package static let standard = StreamChannels(
		names: ["watts", "heartrate", "cadence", "time", "altitude"])

	package let names: [String]

	package init(requested: [String]?) throws(UnusableChannelName) {
		guard let requested, !requested.isEmpty else {
			self = .standard
			return
		}
		if let unusable = requested.first(where: { $0.isEmpty || $0.contains(",") }) {
			throw UnusableChannelName(name: unusable)
		}
		self.init(names: requested)
	}

	private init(names: [String]) {
		self.names = names
	}
}

package struct UnusableChannelName: Error, Equatable {
	package let name: String
}

package struct Readings<Field: Hashable & Sendable>: Sendable, Equatable {
	private let values: [Field: Double]

	package init(_ values: [Field: Double]) {
		self.values = values.filter(\.value.isFinite)
	}

	package subscript(field: Field) -> Double? { values[field] }

	package var isEmpty: Bool { values.isEmpty }

	package func keeping(_ isShown: (Field, Double) -> Bool) -> Readings<Field> {
		Readings(values.filter { isShown($0.key, $0.value) })
	}
}

package enum ReportedNumber: Sendable, Equatable {
	case absent
	case number(Double)
	case notANumber
}

package struct FTPWatts: Sendable, Equatable {
	package let value: Double

	package init?(_ reported: Double) {
		let range = IntervalsPolicy.ftpRange
		guard reported >= Double(range.lowerBound), reported <= Double(range.upperBound) else {
			return nil
		}
		self.value = reported
	}
}

package enum FTPReading: Sendable, Equatable {
	case absent
	case usable(FTPWatts)
	case implausible(reported: Double?)

	package init(_ reported: ReportedNumber) {
		switch reported {
		case .absent:
			self = .absent
		case .number(let watts):
			self = FTPWatts(watts).map(FTPReading.usable) ?? .implausible(reported: watts)
		case .notANumber:
			self = .implausible(reported: nil)
		}
	}
}

package enum ProfileField: String, Hashable, Sendable, CaseIterable {
	case lthr
	case maxHeartRate
	case restingHeartRate
	case weight
	case indoorFTP = "indoorFtp"
	case wPrime
	case maxPower
	case sweetSpotMin
	case sweetSpotMax
}

package struct TrainingZone: Sendable, Equatable {
	package let name: String?
	package let upperBound: Double

	package init(name: String?, upperBound: Double) {
		self.name = name
		self.upperBound = upperBound
	}
}

package struct AthleteProfile: Sendable, Equatable {
	package let id: String
	package let name: String
	package let ftp: FTPReading
	package let readings: Readings<ProfileField>
	package let sex: String?
	package let dateOfBirth: CivilDate?
	package let settingsSports: [String]
	package let powerZones: [TrainingZone]
	package let heartRateZones: [TrainingZone]

	package init(
		id: String, name: String, ftp: FTPReading, readings: Readings<ProfileField>,
		sex: String? = nil, dateOfBirth: CivilDate? = nil, settingsSports: [String] = [],
		powerZones: [TrainingZone] = [], heartRateZones: [TrainingZone] = []
	) {
		self.id = id
		self.name = name
		self.ftp = ftp
		self.readings = readings
		self.sex = sex
		self.dateOfBirth = dateOfBirth
		self.settingsSports = settingsSports
		self.powerZones = powerZones
		self.heartRateZones = heartRateZones
	}

	package func ageYears(on today: CivilDate) -> Int? {
		guard let dateOfBirth, dateOfBirth <= today else { return nil }
		let born = CalendarDay(dateOfBirth)
		let now = CalendarDay(today)
		let birthdayReached = (now.month, now.day) >= (born.month, born.day)
		return now.year - born.year - (birthdayReached ? 0 : 1)
	}
}

private struct CalendarDay {
	let year: Int
	let month: Int
	let day: Int

	init(_ date: CivilDate) {
		let key = DateKey.from(date).rawValue
		year = key / 10_000
		month = key / 100 % 100
		day = key % 100
	}
}

package enum WellnessField: String, Hashable, Sendable, CaseIterable {
	case fitness
	case fatigue
	case rampRate
	case weight
	case restingHeartRate
	case hrv
	case sleepSeconds
	case sleepScore
	case sleepQuality
	case readiness
	case soreness
	case stress
	case mood
	case motivation
	case injury
	case reportedFatigue
}

public struct WellnessDay: Sendable, Equatable {
	public let date: CivilDate
	package let readings: Readings<WellnessField>

	package init(date: CivilDate, readings: Readings<WellnessField>) {
		self.date = date
		self.readings = readings
	}

	public var fitness: Double? { readings[.fitness] }
	public var fatigue: Double? { readings[.fatigue] }

	public var form: Double? {
		guard let fitness, let fatigue else { return nil }
		return fitness - fatigue
	}
}
