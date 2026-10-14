import Foundation

@testable import EnduragentCoach

enum LiveReadAudit {
	private enum ProfileSource {
		case athlete(String)
		case settings(String)
	}

	private static let profileKeys: KeyValuePairs<String, [ProfileSource]> = [
		"ftp": [.settings("ftp"), .athlete("icu_ftp")],
		"lthr": [.settings("lthr"), .athlete("icu_lthr")],
		"maxHeartRate": [.settings("max_hr"), .athlete("icu_max_hr")],
		"restingHeartRate": [.settings("resting_hr"), .athlete("icu_resting_hr")],
		"weight": [.athlete("icu_weight"), .athlete("weight"), .settings("weight")],
		"indoorFtp": [.settings("indoor_ftp")],
		"wPrime": [.settings("w_prime")],
		"maxPower": [.settings("p_max")],
		"sweetSpotMin": [.settings("sweet_spot_min")],
		"sweetSpotMax": [.settings("sweet_spot_max")],
		"sex": [.athlete("sex")],
		"ageYears": [.athlete("icu_date_of_birth")],
		"sports": [.settings("types")],
		"powerZones": [.settings("power_zones")],
		"heartRateZones": [.settings("hr_zones")],
	]

	static let wellnessKeys: KeyValuePairs<String, String> = [
		"ctl": "fitness", "atl": "fatigue", "rampRate": "rampRate", "weight": "weight",
		"restingHR": "restingHeartRate", "hrv": "hrv", "sleepSecs": "sleepSeconds",
		"sleepScore": "sleepScore", "sleepQuality": "sleepQuality", "readiness": "readiness",
		"soreness": "soreness", "stress": "stress", "mood": "mood", "motivation": "motivation",
		"injury": "injury", "fatigue": "reportedFatigue",
	]

	static let activityKeys: KeyValuePairs<String, String> = [
		"name": "name", "type": "sport", "start_date_local": "start",
		"moving_time": "durationSeconds", "distance": "distance", "icu_training_load": "load",
		"icu_intensity": "intensity", "icu_average_watts": "averagePower",
		"icu_weighted_avg_watts": "weightedPower", "average_heartrate": "averageHeartRate",
		"max_heartrate": "maxHeartRate", "icu_ftp": "ftp", "total_elevation_gain": "elevationGain",
	]

	static let detailKeys: KeyValuePairs<String, String> = [
		"description": "notes", "trainer": "indoor", "icu_rpe": "rpe", "feel": "feel",
		"average_cadence": "averageCadence", "average_speed": "averageSpeed",
		"max_speed": "maxSpeed", "calories": "calories", "icu_joules": "work",
		"icu_variability_index": "variabilityIndex", "icu_efficiency_factor": "efficiencyFactor",
		"decoupling": "decoupling", "icu_zone_times": "powerZoneSeconds",
		"icu_hr_zone_times": "heartRateZoneSeconds",
	]

	static let lapKeys: KeyValuePairs<String, String> = [
		"label": "label", "type": "kind", "moving_time": "durationSeconds", "distance": "distance",
		"training_load": "load", "intensity": "intensity", "average_watts": "averagePower",
		"weighted_average_watts": "weightedPower", "average_heartrate": "averageHeartRate",
		"max_heartrate": "maxHeartRate", "total_elevation_gain": "elevationGain",
	]

	static func profile(raw: JSONValue, given: JSONValue) -> [String] {
		let athlete = raw.objectFields
		let settings = cyclingSettings(of: athlete)
		let shown = given.objectFields
		return profileKeys.compactMap { key, sources in
			let supplied = sources.first { source in
				switch source {
				case .athlete(let wire): hasValue(athlete[wire])
				case .settings(let wire): hasValue(settings[wire])
				}
			}
			guard let supplied else { return nil }
			let present = key == "ftp" ? shown["ftp"] ?? shown["ftpUsable"] : shown[key]
			guard present == nil else { return nil }
			return
				"profile: the response has \(name(of: supplied)) but the coach is given no \(key)"
		}
	}

	static func wellness(raw: JSONValue, given: JSONValue) -> [String] {
		let days = Dictionary(
			(given.objectFields["days"]?.arrayValue ?? []).compactMap { day in
				day.objectFields["date"]?.stringValue.map { ($0, day.objectFields) }
			}, uniquingKeysWith: { first, _ in first })
		return (raw.arrayValue ?? []).flatMap { row -> [String] in
			let fields = row.objectFields
			guard let date = fields["id"]?.stringValue else {
				return ["wellness: a row has no date id"]
			}
			guard let day = days[date] else {
				return ["wellness \(date): the response has the row but the coach is given no day"]
			}
			return missing(fields, in: day, by: wellnessKeys, as: "wellness \(date)")
		}
	}

	static func activities(raw: JSONValue, given: JSONValue) -> [String] {
		let shown = given.objectFields
		let listed = Dictionary(
			(shown["activities"]?.arrayValue ?? []).compactMap { row in
				row.objectFields["id"]?.stringValue.map { ($0, row.objectFields) }
			}, uniquingKeysWith: { first, _ in first })
		var findings: [String] = []
		var hidden = 0
		for row in raw.arrayValue ?? [] {
			let fields = row.objectFields
			if isHiddenByStrava(fields) {
				hidden += 1
				continue
			}
			guard let id = identifier(fields["id"]) else {
				findings.append("activities: a row has no identifier")
				continue
			}
			guard let activity = listed[id] else {
				findings.append(
					"activity \(id): the response lists it but the coach is not given it")
				continue
			}
			findings += missing(fields, in: activity, by: activityKeys, as: "activity \(id)")
		}
		if shown["hiddenByStrava"]?.numberValue != Double(hidden) {
			findings.append(
				"activities: \(hidden) rows are hidden by Strava but the coach is told \(shown["hiddenByStrava"].map(canonicalJSON) ?? "nothing")"
			)
		}
		return findings
	}

	static func activity(raw: JSONValue, given: JSONValue) -> [String] {
		let fields = raw.objectFields
		let shown = given.objectFields
		let label = "activity \(identifier(fields["id"]) ?? "without id")"
		if isHiddenByStrava(fields) {
			return shown["error"]?.stringValue == "activity_hidden_by_strava"
				? [] : ["\(label): hidden by Strava but the coach is not told so"]
		}
		guard let activity = shown["activity"]?.objectFields else {
			return ["\(label): the response has the activity but the coach is given none"]
		}
		var findings = missing(fields, in: activity, by: activityKeys, as: label)
		findings += missing(fields, in: activity, by: detailKeys, as: label)
		guard let rawLaps = fields["icu_intervals"]?.arrayValue else { return findings }
		guard let laps = shown["laps"]?.arrayValue, laps.count == rawLaps.count else {
			return findings + [
				"\(label): the response has \(rawLaps.count) laps but the coach is given \(shown["laps"]?.arrayValue?.count ?? 0)"
			]
		}
		for (index, lap) in rawLaps.enumerated() {
			findings += missing(
				lap.objectFields, in: laps[index].objectFields, by: lapKeys,
				as: "\(label) lap \(index + 1)")
		}
		return findings
	}

	static func streams(raw: JSONValue, given: JSONValue) -> [String] {
		let channels = given.objectFields["channels"]?.objectFields ?? [:]
		let sent: [(String?, JSONValue?)] =
			switch raw {
			case .array(let entries):
				entries.map { ($0.objectFields["type"]?.stringValue, $0.objectFields["data"]) }
			case .object(let fields): fields.map { ($0.key, $0.value) }
			default: []
			}
		return sent.compactMap { channel, data in
			guard let channel,
				(data?.arrayValue ?? []).contains(where: { $0.numberValue?.isFinite == true }),
				channels[channel] == nil
			else { return nil }
			return "streams: the response has samples for \(channel) but the coach is given none"
		}
	}

	static func streamNames(_ name: String, asked: [String], outcome: LiveReadOutcome)
		-> [String]
	{
		guard let given = outcome.given else { return [] }
		let channels = given.objectFields["channels"]?.objectFields ?? [:]
		let lists = LiveParkedQuestions.streamLists(given)
		var findings: [String] = []
		for channel in Set(asked).sorted() where channels[channel] == nil {
			let named = lists.filter { $0.value.contains(channel) }.keys.sorted()
			if named.count != 1 {
				findings.append(
					"\(name): the coach is given \(channel) under \(named.isEmpty ? "no list" : named.joined(separator: " and ")) instead of exactly one of unanswered, unknown or unread"
				)
			}
		}
		for rejected in outcome.responses.compactMap(rejectedStreamType)
		where lists["unknown"]?.contains(rejected) != true {
			findings.append(
				"\(name): intervals.icu rejected \(rejected) as an invalid stream type, but the coach is not given it under unknown"
			)
		}
		return findings
	}

	static func rejectedStreamType(_ response: TappedResponse) -> String? {
		let prefix = "Invalid stream type ["
		guard response.status == 422,
			let message = response.json?.objectFields["error"]?.stringValue,
			message.hasPrefix(prefix), message.hasSuffix("]")
		else { return nil }
		return String(message.dropFirst(prefix.count).dropLast())
	}

	static func snapshotOutOfRange(_ section: String) -> [String] {
		let bands: [(label: String, unit: String, range: ClosedRange<Double>)] = [
			(
				"FTP", "W",
				Double(
					IntervalsPolicy.ftpRange.lowerBound)...Double(
						IntervalsPolicy.ftpRange.upperBound)
			),
			("weight", "kg", SnapshotPolicy.weightKilograms),
			("resting HR", "bpm", SnapshotPolicy.restingHeartRate),
		]
		var findings: [String] = []
		for line in section.split(separator: "\n")
		where line.hasPrefix("Profile: ") || line.hasPrefix("Wellness ") {
			let body = line.drop { $0 != ":" }.dropFirst()
			for part in body.components(separatedBy: " · ") {
				let shown = part.trimmingCharacters(in: .whitespaces)
				for band in bands where shown.hasPrefix(band.label + " ") {
					let rest = shown.dropFirst(band.label.count + 1)
					guard rest.hasSuffix(" " + band.unit), !shown.hasSuffix("(not usable)"),
						let value = Double(rest.dropLast(band.unit.count + 1))
					else { continue }
					if !band.range.contains(value) {
						findings.append("snapshot: \(shown) is outside \(band.range)")
					}
				}
			}
		}
		return findings
	}

	static func isHiddenByStrava(_ fields: [String: JSONValue]) -> Bool {
		fields["source"]?.stringValue == "STRAVA"
			&& ["type", "moving_time", "elapsed_time"].contains { !hasValue(fields[$0]) }
	}

	static func identifier(_ value: JSONValue?) -> String? {
		switch value {
		case .string(let raw)?: raw
		case .number?: value?.intValue().map(String.init)
		default: nil
		}
	}

	static func cyclingSettings(of athlete: [String: JSONValue]) -> [String: JSONValue] {
		let rows = (athlete["sportSettings"]?.arrayValue ?? []).map(\.objectFields)
		let cycling = rows.first { row in
			(row["types"]?.arrayValue ?? []).contains {
				$0.stringValue.map(IntervalsPolicy.cyclingSports.contains) ?? false
			}
		}
		return cycling ?? rows.first ?? [:]
	}

	static func hasValue(_ value: JSONValue?) -> Bool {
		switch value {
		case nil, .null?: false
		case .array(let entries)?: !entries.isEmpty
		case .string(let text)?: !text.isEmpty
		default: true
		}
	}

	private static func missing(
		_ wire: [String: JSONValue], in shown: [String: JSONValue],
		by keys: KeyValuePairs<String, String>, as label: String
	) -> [String] {
		keys.compactMap { wireKey, shownKey in
			guard hasValue(wire[wireKey]), shown[shownKey] == nil else { return nil }
			return "\(label): the response has \(wireKey) but the coach is given no \(shownKey)"
		}
	}

	private static func name(of source: ProfileSource) -> String {
		switch source {
		case .athlete(let key): "athlete \(key)"
		case .settings(let key): "cycling settings \(key)"
		}
	}
}
