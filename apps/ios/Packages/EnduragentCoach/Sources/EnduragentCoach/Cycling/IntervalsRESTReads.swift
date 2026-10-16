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
			dateOfBirth: athlete["icu_date_of_birth"]?.stringValue.flatMap(
				CivilDate.init(rawValue:)),
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
		return ActivityListing(range: range, rows: rows.map { Self.classify($0.objectFields) })
	}

	package func activity(_ id: ActivityID) async throws -> ActivityDetailRead {
		let json: JSONValue
		do {
			json = try await getJSON(
				path: ["activity", id.rawValue],
				query: [URLQueryItem(name: "intervals", value: "true")])
		} catch let error as IntervalsError where error.status == 404 {
			return .notFound
		}
		guard case .object(let fields) = json else {
			throw IntervalsError(
				code: "invalid_json", details: "activity response was not an object")
		}
		return try Self.classifyDetail(fields, asked: id)
	}

	private static func classify(_ fields: [String: JSONValue]) -> ActivityRow {
		if isHiddenByStrava(fields) { return .hiddenByStrava }
		guard let activity = activity(from: fields) else { return .unreadable }
		return .activity(activity)
	}

	private static func classifyDetail(_ fields: [String: JSONValue], asked id: ActivityID)
		throws(IntervalsError) -> ActivityDetailRead
	{
		if let answered = activityID(in: fields), answered != id {
			throw IntervalsError.activityMismatch(asked: id)
		}
		if isHiddenByStrava(fields) { return .hiddenByStrava }
		guard let activity = activity(from: fields) else {
			throw IntervalsError(
				code: "invalid_json",
				details: "activity response had no usable identifier or start")
		}
		return .found(
			try ActivityDetail(
				asked: id, activity: activity, extras: extras(from: fields),
				laps: try laps(from: fields["icu_intervals"])))
	}

	private static func isHiddenByStrava(_ fields: [String: JSONValue]) -> Bool {
		guard fields["source"]?.stringValue == IntervalsPolicy.stravaSource else { return false }
		let lacksATime = ["moving_time", "elapsed_time"].contains { key in
			guard let seconds = number(fields[key]) else { return true }
			return seconds < 0
		}
		return fields["type"]?.stringValue == nil || lacksATime
	}

	private static func number(_ wire: JSONValue?) -> Double? {
		guard case .number(let value) = ReportedNumber(wire: wire) else { return nil }
		return value
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
		return WellnessDay(
			date: date, readings: readings(in: fields, under: \WellnessField.wireKey))
	}

	static func activityID(in fields: [String: JSONValue]) -> ActivityID? {
		switch fields["id"] {
		case .string(let raw)?: ActivityID(rawValue: raw)
		case .number(let number)?:
			JSONValue.number(number).intValue().flatMap { ActivityID(rawValue: String($0)) }
		default: nil
		}
	}

	private static func activity(from fields: [String: JSONValue]) -> Activity? {
		guard let id = activityID(in: fields),
			let start = fields["start_date_local"]?.stringValue.flatMap(localStart)
		else { return nil }
		return Activity(
			id: id, name: fields["name"]?.stringValue, sport: fields["type"]?.stringValue,
			start: start, readings: readings(in: fields, under: \ActivityField.wireKey),
			ftp: number(fields["icu_ftp"]))
	}

	private static func readings<Field: Hashable & Sendable & CaseIterable>(
		in fields: [String: JSONValue], under key: (Field) -> String
	) -> Readings<Field> {
		var readings: [Field: Double] = [:]
		for field in Field.allCases {
			readings[field] = number(fields[key(field)])
		}
		return Readings(readings)
	}

	private static func laps(from wire: JSONValue?) throws(IntervalsError) -> Laps {
		switch wire {
		case nil, .null?:
			return .notSupplied
		case .array(let entries)?:
			return .recorded(
				entries.enumerated().map { index, entry in
					let fields = entry.objectFields
					return ActivityLap(
						number: index + 1, label: fields["label"]?.stringValue,
						kind: fields["type"]?.stringValue,
						readings: readings(in: fields, under: \ActivityField.lapWireKey))
				})
		default:
			throw IntervalsError(code: "invalid_json", details: "activity laps were not a list")
		}
	}

	private static func extras(from fields: [String: JSONValue]) -> ActivityDetailExtras {
		ActivityDetailExtras(
			notes: fields["description"]?.stringValue, indoor: fields["trainer"]?.boolValue,
			readings: readings(in: fields, under: \ActivityDetailField.wireKey),
			powerZoneSeconds: (fields["icu_zone_times"]?.arrayValue ?? []).compactMap { entry in
				let zone = entry.objectFields
				guard let name = zone["id"]?.stringValue, let seconds = wholeSeconds(zone["secs"])
				else { return nil }
				return ZoneSeconds(zone: name, seconds: seconds)
			},
			heartRateZoneSeconds: heartRateZoneSeconds(fields["icu_hr_zone_times"]))
	}

	private static func heartRateZoneSeconds(_ wire: JSONValue?) -> [Int] {
		var ladder: [Int] = []
		for entry in wire?.arrayValue ?? [] {
			guard let seconds = wholeSeconds(entry) else { return [] }
			ladder.append(seconds)
		}
		return ladder
	}

	private static func wholeSeconds(_ wire: JSONValue?) -> Int? {
		guard case .number(let value)? = wire, value >= 0 else { return nil }
		return JSONValue.number(value).intValue()
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
		case .elevationGain: "total_elevation_gain"
		}
	}
}

extension ActivityField {
	fileprivate var lapWireKey: String {
		switch self {
		case .duration: "moving_time"
		case .distance: "distance"
		case .load: "training_load"
		case .intensity: "intensity"
		case .averagePower: "average_watts"
		case .weightedPower: "weighted_average_watts"
		case .averageHeartRate: "average_heartrate"
		case .maxHeartRate: "max_heartrate"
		case .elevationGain: "total_elevation_gain"
		}
	}
}

extension ActivityDetailField {
	fileprivate var wireKey: String {
		switch self {
		case .perceivedExertion: "icu_rpe"
		case .feel: "feel"
		case .averageCadence: "average_cadence"
		case .averageSpeed: "average_speed"
		case .maxSpeed: "max_speed"
		case .calories: "calories"
		case .work: "icu_joules"
		case .variabilityIndex: "icu_variability_index"
		case .efficiencyFactor: "icu_efficiency_factor"
		case .decoupling: "decoupling"
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
