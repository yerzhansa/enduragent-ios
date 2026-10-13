import Foundation

extension IntervalsRESTClient: TrainingReads {
	package func profile() async throws -> AthleteProfile {
		let athlete = try await getJSON(path: ["athlete", athletePath]).objectFields
		let settings = Self.cyclingSettings(of: athlete)
		let wire = ProfileWire(athlete: athlete, settings: settings)
		var readings: [ProfileField: Double] = [:]
		for field in ProfileField.allCases {
			if case .number(let value) = wire.resolve(field.sources) {
				readings[field] = value
			}
		}
		return AthleteProfile(
			id: athlete["id"]?.stringValue ?? athletePath,
			name: athlete["name"]?.stringValue ?? "",
			ftp: FTPReading(wire.resolve([.settings("ftp"), .athlete("icu_ftp")])),
			readings: Readings(readings),
			sex: athlete["sex"]?.stringValue,
			ageYears: Self.wholeYears(
				since: athlete["icu_date_of_birth"],
				on: IntervalsPolicy.today(now: clock.now, timeZone: clock.timeZone)),
			settingsSports: (settings["types"]?.arrayValue ?? []).compactMap(\.stringValue),
			powerZones: Self.zones(
				bounds: settings["power_zones"], names: settings["power_zone_names"]),
			heartRateZones: Self.zones(
				bounds: settings["hr_zones"], names: settings["hr_zone_names"])
		)
	}

	package func wellness(in range: ReadRange) async throws -> [WellnessDay] {
		let json = try await getJSON(
			path: ["athlete", athletePath, "wellness"],
			query: [
				URLQueryItem(name: "oldest", value: range.oldest.rawValue),
				URLQueryItem(name: "newest", value: range.newest.rawValue),
			]
		)
		guard let rows = json.arrayValue else {
			throw IntervalsError(
				code: "invalid_json", details: "wellness response was not an array")
		}
		return rows.compactMap(Self.wellnessDay(from:))
	}

	package func activities(in range: ReadRange) async throws -> ActivityListing {
		let json = try await getJSON(
			path: ["athlete", athletePath, "activities"],
			query: [
				URLQueryItem(name: "oldest", value: range.oldest.rawValue),
				URLQueryItem(name: "newest", value: range.newest.rawValue),
			]
		)
		guard let rows = json.arrayValue else {
			throw IntervalsError(
				code: "invalid_json", details: "activities response was not an array")
		}
		return ActivityListing(range: range, rows: rows.map(Self.activityRow(from:)))
	}

	private static func cyclingSettings(of athlete: [String: JSONValue]) -> [String: JSONValue] {
		let rows: [[String: JSONValue]] = (athlete["sportSettings"]?.arrayValue ?? []).compactMap {
			guard case .object(let row) = $0 else { return nil }
			return row
		}
		let cycling = rows.first { row in
			(row["types"]?.arrayValue ?? []).contains { type in
				type.stringValue.map(IntervalsPolicy.cyclingSports.contains) ?? false
			}
		}
		return cycling ?? rows.first ?? [:]
	}

	private static func wholeYears(since birth: JSONValue?, on today: CivilDate) -> Int? {
		guard let born = birth?.stringValue.flatMap(CivilDate.init(rawValue:)), born <= today
		else { return nil }
		return (DateKey.from(today).rawValue - DateKey.from(born).rawValue) / 10_000
	}

	private static func zones(bounds: JSONValue?, names: JSONValue?) -> [TrainingZone] {
		let names = names?.arrayValue ?? []
		var ladder: [TrainingZone] = []
		for (index, bound) in (bounds?.arrayValue ?? []).enumerated() {
			guard case .number(let upperBound) = ReportedNumber(wire: bound) else { return [] }
			ladder.append(
				TrainingZone(
					name: index < names.count ? names[index].stringValue : nil,
					upperBound: upperBound))
		}
		return ladder
	}

	private static func wellnessDay(from row: JSONValue) -> WellnessDay? {
		let fields = row.objectFields
		guard let date = fields["id"]?.stringValue.flatMap(CivilDate.init(rawValue:)) else {
			return nil
		}
		var readings: [WellnessField: Double] = [:]
		for field in WellnessField.allCases {
			if case .number(let value) = ReportedNumber(wire: fields[field.wireKey]) {
				readings[field] = value
			}
		}
		return WellnessDay(date: date, readings: Readings(readings))
	}

	private static func activityRow(from row: JSONValue) -> ActivityRow {
		let fields = row.objectFields
		func number(_ key: String) -> Double? {
			guard case .number(let value) = ReportedNumber(wire: fields[key]) else { return nil }
			return value
		}
		return ActivityRow(
			source: fields["source"]?.stringValue, sport: fields["type"]?.stringValue,
			movingTime: number("moving_time"), elapsedTime: number("elapsed_time"),
			activity: activity(from: fields))
	}

	private static func activity(from fields: [String: JSONValue]) -> Activity? {
		let id: ActivityID? =
			switch fields["id"] {
			case .string(let raw)?: ActivityID(rawValue: raw)
			case .number(let number)?:
				JSONValue.number(number).intValue().flatMap { ActivityID(rawValue: String($0)) }
			default: nil
			}
		guard let id, let start = fields["start_date_local"]?.stringValue.flatMap(localStart)
		else { return nil }
		var readings: [ActivityField: Double] = [:]
		for field in ActivityField.allCases {
			if case .number(let value) = ReportedNumber(wire: fields[field.wireKey]) {
				readings[field] = value
			}
		}
		return Activity(
			id: id, name: fields["name"]?.stringValue, sport: fields["type"]?.stringValue,
			start: start, readings: Readings(readings))
	}

	private static func localStart(_ wire: String) -> LocalStart? {
		guard let date = CivilDate(rawValue: String(wire.prefix(10))) else { return nil }
		let time = wire.dropFirst(10)
		if time.isEmpty { return LocalStart(date: date, secondOfDay: nil) }
		let parts = time.dropFirst().split(separator: ":", omittingEmptySubsequences: false)
		guard time.first == "T", parts.count == 3,
			parts.allSatisfy({ $0.count == 2 && $0.allSatisfy { $0.isASCII && $0.isNumber } }),
			let hour = Int(parts[0]), let minute = Int(parts[1]), let second = Int(parts[2]),
			hour < 24, minute < 60, second < 60
		else { return nil }
		return LocalStart(date: date, secondOfDay: hour * 3_600 + minute * 60 + second)
	}
}

private enum ProfileSource {
	case settings(String)
	case athlete(String)
}

private struct ProfileWire {
	let athlete: [String: JSONValue]
	let settings: [String: JSONValue]

	func resolve(_ sources: [ProfileSource]) -> ReportedNumber {
		for source in sources {
			let reported =
				switch source {
				case .settings(let key): ReportedNumber(wire: settings[key])
				case .athlete(let key): ReportedNumber(wire: athlete[key])
				}
			if reported != .absent { return reported }
		}
		return .absent
	}
}

extension ReportedNumber {
	fileprivate init(wire value: JSONValue?) {
		switch value {
		case nil, .null?:
			self = .absent
		case .number(let number)? where number.isFinite:
			self = .number(number)
		default:
			self = .notANumber
		}
	}
}

extension ProfileField {
	fileprivate var sources: [ProfileSource] {
		switch self {
		case .lthr: [.settings("lthr"), .athlete("icu_lthr")]
		case .maxHeartRate: [.settings("max_hr"), .athlete("icu_max_hr")]
		case .restingHeartRate: [.settings("resting_hr"), .athlete("icu_resting_hr")]
		case .weight: [.athlete("icu_weight"), .athlete("weight"), .settings("weight")]
		case .indoorFTP: [.settings("indoor_ftp")]
		case .wPrime: [.settings("w_prime")]
		case .maxPower: [.settings("p_max")]
		case .sweetSpotMin: [.settings("sweet_spot_min")]
		case .sweetSpotMax: [.settings("sweet_spot_max")]
		}
	}
}

extension ActivityField {
	fileprivate var wireKey: String {
		switch self {
		case .duration: "moving_time"
		case .distance: "distance"
		case .load: "icu_training_load"
		case .intensity: "icu_intensity"
		case .averagePower: "icu_average_watts"
		case .weightedPower: "icu_weighted_avg_watts"
		case .averageHeartRate: "average_heartrate"
		case .maxHeartRate: "max_heartrate"
		case .ftp: "icu_ftp"
		case .elevationGain: "total_elevation_gain"
		}
	}
}

extension WellnessField {
	fileprivate var wireKey: String {
		switch self {
		case .fitness: "ctl"
		case .fatigue: "atl"
		case .rampRate: "rampRate"
		case .weight: "weight"
		case .restingHeartRate: "restingHR"
		case .hrv: "hrv"
		case .sleepSeconds: "sleepSecs"
		case .sleepScore: "sleepScore"
		case .sleepQuality: "sleepQuality"
		case .readiness: "readiness"
		case .soreness: "soreness"
		case .stress: "stress"
		case .mood: "mood"
		case .motivation: "motivation"
		case .injury: "injury"
		case .reportedFatigue: "fatigue"
		}
	}
}
