import Foundation

extension CoachTools {
	private static let activityIDDescription =
		"Activity ID from intervals_fetch_activities — a positive integer or digit string, optionally i-prefixed for intervals-native activities, or a lowercase 64-hex canonical ID. Pass exactly as listed."

	static let fetchAthlete = CoachTool.training(
		.intervalsFetchAthlete,
		"Fetch athlete profile from intervals.icu (FTP, weight, max HR, sport settings, zones)",
		parameters: ToolParameters.none
	) { _, reach in
		.result(CoachReadout.profile(try await reach.reads.profile()))
	}

	static let fetchWellness = CoachTool.training(
		.intervalsFetchWellness,
		"Fetch wellness data from intervals.icu (fitness, fatigue, weight, HRV, resting HR, sleep). Form = fitness - fatigue.",
		parameters: ToolParameters.object(
			properties: [
				"oldest": ToolParameters.string("Start date (YYYY-MM-DD)"),
				"newest": ToolParameters.string("End date (YYYY-MM-DD)"),
			],
			required: ["oldest"]
		)
	) { arguments, reach in
		let range = try arguments.readRange(today: reach.local.today)
		return .result(CoachReadout.wellness(try await reach.reads.wellness(in: range), in: range))
	}

	static let fetchActivity = CoachTool.training(
		.intervalsFetchActivity,
		"Fetch one recorded activity by legacy or canonical ID. Store-backed results return a bounded source-neutral summary plus laps; other readers may include additional source fields. Use only fields actually returned. Use this for Tier B+ workout reviews; for summary-only Tier A, use `intervals_fetch_activities`.",
		parameters: ToolParameters.object(
			properties: [
				"activityId": ToolParameters.string(activityIDDescription)
			],
			required: ["activityId"]
		)
	) { arguments, reach in
		.result(try await reach.calendar.fetchActivity(id: try arguments.activityID()))
	}

	static let fetchStreams = CoachTool.training(
		.intervalsFetchStreams,
		"Fetch time-series channels for an activity by legacy or canonical ID. Store-backed reads accept up to 16 unique public channels; platform-backed reads also accept provider-specific channels such as smooth_grade. Returns only per-channel min/max/mean over the full series plus the sample count; no per-second data; do not use it for pacing, duration-based best efforts, quartile trends, decoupling, HR recovery, fade patterns, or indoor/outdoor comparisons. Use only minimum, maximum, and mean as descriptive recorded observations. They alone cannot establish session quality, recovery, or readiness, or justify changing the next session. Expensive to fetch (~10,800 samples per type for a 3-hour ride): call it only for Tier C deep reviews the athlete explicitly requests. For Tier A/B use `intervals_fetch_activities` and `intervals_fetch_activity`. Default types: watts, heartrate, cadence, time, altitude.",
		parameters: ToolParameters.object(
			properties: [
				"activityId": ToolParameters.string(activityIDDescription),
				"types": .object([
					"type": .string("array"),
					"items": .object(["type": .string("string")]),
					"description": .string(
						"Channel names; defaults to watts, heartrate, cadence, time, altitude."
					),
				]),
			],
			required: ["activityId"]
		)
	) { arguments, reach in
		.result(try await reach.calendar.fetchStreams(id: try arguments.activityID()))
	}

	static let fetchActivities = CoachTool.training(
		.intervalsFetchActivities,
		"Fetch up to 200 recorded activity summaries for a date range. Store-backed results use positive integer or lowercase 64-hex IDs and a bounded source-neutral shape; other readers may include additional source fields. If more than 200 store-backed activities match, narrow the date range.",
		parameters: ToolParameters.object(
			properties: [
				"oldest": ToolParameters.string("Oldest date (YYYY-MM-DD)"),
				"newest": ToolParameters.string("Newest date (YYYY-MM-DD)"),
			],
			required: ["oldest"]
		)
	) { arguments, reach in
		let range = try arguments.readRange(today: reach.local.today)
		return .result(CoachReadout.activities(try await reach.reads.activities(in: range)))
	}
}

enum CoachReadout {
	static func profile(_ profile: AthleteProfile) -> JSONValue {
		var fields: [String: JSONValue] = [
			"id": .string(profile.id),
			"name": .string(profile.name),
		]
		var units: [String: JSONValue] = [:]
		func measure(_ key: String, _ value: JSONValue, unit: String) {
			fields[key] = value
			units[key] = .string(unit)
		}
		switch profile.ftp {
		case .absent:
			break
		case .usable(let watts):
			measure("ftp", .number(watts.value), unit: "W")
		case .implausible(let reported):
			if let reported { measure("ftp", .number(reported), unit: "W") }
			fields["ftpUsable"] = .bool(false)
			fields["ftpNotice"] = .string(PromptStaticBlocks.snapshotQualitativeFTP)
		}
		for field in ProfileField.allCases {
			guard let value = profile.readings[field] else { continue }
			measure(field.readoutKey, .number(value), unit: field.unit)
		}
		if let sex = profile.sex { fields["sex"] = .string(sex) }
		if let age = profile.ageYears { fields["ageYears"] = .number(Double(age)) }
		if !profile.settingsSports.isEmpty {
			fields["sports"] = .array(profile.settingsSports.map(JSONValue.string))
		}
		if !profile.powerZones.isEmpty {
			measure("powerZones", ladder(profile.powerZones), unit: "% of FTP")
		}
		if !profile.heartRateZones.isEmpty {
			measure("heartRateZones", ladder(profile.heartRateZones), unit: "bpm")
		}
		if !units.isEmpty { fields["units"] = .object(units) }
		return .object(fields)
	}

	private static func ladder(_ zones: [TrainingZone]) -> JSONValue {
		.array(
			zones.map { zone in
				var fields: [String: JSONValue] = ["upTo": .number(zone.upperBound)]
				if let name = zone.name { fields["name"] = .string(name) }
				return .object(fields)
			})
	}

	static func wellness(_ days: [WellnessDay], in range: ReadRange) -> JSONValue {
		var units: [String: JSONValue] = [:]
		let rows = days.sorted { $0.date < $1.date }.map { day in
			var fields: [String: JSONValue] = ["date": .string(day.date.rawValue)]
			for field in WellnessField.allCases {
				guard let value = day.readings[field] else { continue }
				fields[field.readoutKey] = .number(value)
				if let unit = field.unit { units[field.readoutKey] = .string(unit) }
			}
			if let form = day.form { fields["form"] = .number(OneDecimal.round(form)) }
			return JSONValue.object(fields)
		}
		var result: [String: JSONValue] = [
			"oldest": .string(range.oldest.rawValue),
			"newest": .string(range.newest.rawValue),
			"days": .array(rows),
		]
		if !units.isEmpty { result["units"] = .object(units) }
		return .object(result)
	}

	static func activities(_ listing: ActivityListing) -> JSONValue {
		var units: [String: JSONValue] = [:]
		var result: [String: JSONValue] = [
			"oldest": .string(listing.range.oldest.rawValue),
			"newest": .string(listing.range.newest.rawValue),
			"activities": .array(listing.activities.map { row(of: $0, units: &units) }),
			"hiddenByStrava": .number(Double(listing.hiddenByStrava)),
		]
		if listing.hiddenByStrava > 0 {
			result["stravaNotice"] = .string(
				stravaNotice(hidden: listing.hiddenByStrava, of: listing.total))
		}
		if listing.unreadable > 0 { result["unreadable"] = .number(Double(listing.unreadable)) }
		if !units.isEmpty { result["units"] = .object(units) }
		return .object(result)
	}

	static func stravaNotice(hidden: Int, of total: Int) -> String {
		"\(hidden) of \(total) activities are hidden by Strava, so they aren’t included. Strava does not allow third-party AI tools to use data from its API. For future rides, connect your recording source directly to intervals.icu and keep Strava connected. For past rides, use Import All Strava Data in intervals.icu settings; it requires an intervals.icu supporter subscription."
	}

	private static func row(of activity: Activity, units: inout [String: JSONValue]) -> JSONValue {
		var fields: [String: JSONValue] = [
			"id": .string(activity.id.rawValue),
			"start": .string(activity.start.readout),
		]
		if let name = activity.name { fields["name"] = .string(name) }
		if let sport = activity.sport { fields["sport"] = .string(sport) }
		for field in ActivityField.allCases {
			guard let value = activity.readings[field] else { continue }
			fields[field.readoutKey] = .number(value)
			if let unit = field.unit { units[field.readoutKey] = .string(unit) }
		}
		return .object(fields)
	}
}

extension LocalStart {
	var readout: String {
		guard let secondOfDay else { return date.rawValue }
		let clock = [secondOfDay / 3_600, secondOfDay / 60 % 60, secondOfDay % 60]
			.map { $0 < 10 ? "0\($0)" : "\($0)" }
			.joined(separator: ":")
		return "\(date.rawValue)T\(clock)"
	}
}

extension ActivityField {
	var readoutKey: String {
		switch self {
		case .duration: "durationSeconds"
		case .distance: "distance"
		case .load: "load"
		case .intensity: "intensity"
		case .averagePower: "averagePower"
		case .weightedPower: "weightedPower"
		case .averageHeartRate: "averageHeartRate"
		case .maxHeartRate: "maxHeartRate"
		case .ftp: "ftp"
		case .elevationGain: "elevationGain"
		}
	}

	var unit: String? {
		switch self {
		case .duration: "s"
		case .distance, .elevationGain: "m"
		case .load: nil
		case .intensity: "%"
		case .averagePower, .weightedPower, .ftp: "W"
		case .averageHeartRate, .maxHeartRate: "bpm"
		}
	}
}

extension ProfileField {
	var readoutKey: String {
		switch self {
		case .lthr: "lthr"
		case .maxHeartRate: "maxHeartRate"
		case .restingHeartRate: "restingHeartRate"
		case .weight: "weight"
		case .indoorFTP: "indoorFtp"
		case .wPrime: "wPrime"
		case .maxPower: "maxPower"
		case .sweetSpotMin: "sweetSpotMin"
		case .sweetSpotMax: "sweetSpotMax"
		}
	}

	var unit: String {
		switch self {
		case .lthr, .maxHeartRate, .restingHeartRate: "bpm"
		case .weight: "kg"
		case .indoorFTP, .maxPower: "W"
		case .wPrime: "J"
		case .sweetSpotMin, .sweetSpotMax: "% of FTP"
		}
	}
}

extension WellnessField {
	var readoutKey: String {
		switch self {
		case .fitness: "fitness"
		case .fatigue: "fatigue"
		case .rampRate: "rampRate"
		case .weight: "weight"
		case .restingHeartRate: "restingHeartRate"
		case .hrv: "hrv"
		case .sleepSeconds: "sleepSeconds"
		case .sleepScore: "sleepScore"
		case .sleepQuality: "sleepQuality"
		case .readiness: "readiness"
		case .soreness: "soreness"
		case .stress: "stress"
		case .mood: "mood"
		case .motivation: "motivation"
		case .injury: "injury"
		case .reportedFatigue: "reportedFatigue"
		}
	}

	var unit: String? {
		switch self {
		case .rampRate: "Fitness per week"
		case .weight: "kg"
		case .restingHeartRate: "bpm"
		case .hrv: "ms"
		case .sleepSeconds: "s"
		case .fitness, .fatigue, .sleepScore, .sleepQuality, .readiness, .soreness, .stress,
			.mood, .motivation, .injury, .reportedFatigue:
			nil
		}
	}
}

extension JSONValue {
	func readRange(today: CivilDate) throws(IntervalsError) -> ReadRange {
		let fields = objectFields
		if let oldest = try Self.optionalDate(fields["oldest"], label: "oldest") {
			return try ReadRange(
				oldest: oldest, newest: try Self.optionalDate(fields["newest"], label: "newest"),
				today: today)
		}
		throw IntervalsError(
			code: "invalid_date",
			details: "oldest is not a real calendar date. Use YYYY-MM-DD."
		)
	}

	func activityID() throws(IntervalsError) -> ActivityID {
		let value = objectFields["activityId"]
		if let raw = value?.stringValue, let id = ActivityID(rawValue: raw) {
			return id
		}
		if let number = value?.intValue(), let id = ActivityID(rawValue: String(number)) {
			return id
		}
		throw IntervalsError(
			code: "invalid_input",
			details: "activityId must be a positive integer, i-prefixed id, or lowercase 64-hex id."
		)
	}

	private static func optionalDate(_ value: JSONValue?, label: String) throws(IntervalsError)
		-> CivilDate?
	{
		guard let value else { return nil }
		guard let raw = value.stringValue else {
			throw IntervalsError(
				code: "invalid_date",
				details: "\(label) is not a real calendar date. Use YYYY-MM-DD."
			)
		}
		guard let date = CivilDate(rawValue: raw) else {
			throw IntervalsError(
				code: "invalid_date",
				details: "\(raw) is not a real calendar date. Use YYYY-MM-DD."
			)
		}
		return date
	}
}
