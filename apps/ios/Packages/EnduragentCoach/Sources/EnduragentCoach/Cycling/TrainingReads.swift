import Foundation

package protocol TrainingReads: Sendable {
	func profile() async throws -> AthleteProfile
	func wellness(in range: ReadRange) async throws -> [WellnessDay]
	func activities(in range: ReadRange) async throws -> ActivityListing
}

package typealias TrainingClient = TrainingReads & IntervalsClient

package struct ReadRange: Sendable, Equatable {
	package let oldest: CivilDate
	package let newest: CivilDate

	package init(oldest: CivilDate, newest: CivilDate?, today: CivilDate) throws(IntervalsError) {
		let newest = newest ?? today
		if oldest > newest {
			throw IntervalsError(
				code: "invalid_range",
				details: "oldest (\(oldest)) is after newest (\(newest)). Swap the bounds."
			)
		}
		try Self.rejectTooWide(IntervalsPolicy.inclusiveDayCount(from: oldest, to: newest))
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

	package func contains(_ date: CivilDate) -> Bool {
		date >= oldest && date <= newest
	}

	private static func rejectTooWide(_ days: Int) throws(IntervalsError) {
		let limit = IntervalsPolicy.listMaxRangeDays
		if days > limit {
			throw IntervalsError(
				code: "range_too_wide",
				details:
					"Range is \(days) days; the maximum is \(limit). Fetch the range in chunks of at most \(limit) days."
			)
		}
	}
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

package enum OneDecimal {
	package static func round(_ value: Double) -> Double {
		let scaled = value * 10
		let floor = scaled.rounded(.down)
		return (scaled - floor >= 0.5 ? floor + 1 : floor) / 10
	}
}

package enum ProfileField: Hashable, Sendable, CaseIterable {
	case lthr
	case maxHeartRate
	case restingHeartRate
	case weight
	case indoorFTP
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
	package let ageYears: Int?
	package let settingsSports: [String]
	package let powerZones: [TrainingZone]
	package let heartRateZones: [TrainingZone]

	package init(
		id: String, name: String, ftp: FTPReading, readings: Readings<ProfileField>,
		sex: String? = nil, ageYears: Int? = nil, settingsSports: [String] = [],
		powerZones: [TrainingZone] = [], heartRateZones: [TrainingZone] = []
	) {
		self.id = id
		self.name = name
		self.ftp = ftp
		self.readings = readings
		self.sex = sex
		self.ageYears = ageYears
		self.settingsSports = settingsSports
		self.powerZones = powerZones
		self.heartRateZones = heartRateZones
	}
}

package enum WellnessField: Hashable, Sendable, CaseIterable {
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
