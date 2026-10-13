import Foundation

extension IntervalsRESTClient: TrainingReads {
	package func profile() async throws -> AthleteProfile {
		let athlete = try await getJSON(path: ["athlete", athletePath]).objectFields
		let wire = ProfileWire(athlete: athlete, settings: Self.cyclingSettings(of: athlete))
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
			readings: Readings(readings)
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
