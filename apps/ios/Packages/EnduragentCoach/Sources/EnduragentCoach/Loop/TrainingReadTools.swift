import Foundation

extension CoachTools {
	private static let activityIDDescription =
		"Activity `id` from intervals_fetch_activities. Pass exactly as listed."

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
		"Fetch one recorded activity by the `id` that `intervals_fetch_activities` listed, passed exactly as listed. Returns the activity's summary measurements plus `laps` when intervals.icu supplies them; `lapsSupplied: false` means it supplied none. Use only fields actually returned. Use this for Tier B+ workout reviews; for summary-only Tier A, use `intervals_fetch_activities`.",
		parameters: ToolParameters.object(
			properties: [
				"activityId": ToolParameters.string(activityIDDescription)
			],
			required: ["activityId"]
		)
	) { arguments, reach in
		let id = try arguments.activityID()
		do {
			return .result(CoachReadout.activity(try await reach.reads.activity(id), asked: id))
		} catch let error as IntervalsError {
			return .result(CoachReadout.activityUnread(id, error))
		}
	}

	static let fetchStreams = CoachTool.training(
		.intervalsFetchStreams,
		"Fetch time-series channels for an activity by the `id` that `intervals_fetch_activities` listed, passed exactly as listed. Channel names are intervals.icu's own, including provider-specific channels such as grade_smooth. Returns only per-channel min/max/mean over the full series plus the sample count; no per-second data; do not use it for pacing, duration-based best efforts, quartile trends, decoupling, HR recovery, fade patterns, or indoor/outdoor comparisons. Use only minimum, maximum, and mean as descriptive recorded observations. They alone cannot establish session quality, recovery, or readiness, or justify changing the next session. Expensive to fetch (~10,800 samples per type for a 3-hour ride): call it only for Tier C deep reviews the athlete explicitly requests. For Tier A/B use `intervals_fetch_activities` and `intervals_fetch_activity`. Default types: watts, heartrate, cadence, time, altitude. A requested channel with nothing to summarize is named in `unanswered`, and a name intervals.icu does not know is named in `unknown`. When too many requested names are unknown, the read stops early and names the channels it did not read in `unread`; that says nothing about their data, so ask again with only the names you need. A name in any of these lists has no numbers.",
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
		let id = try arguments.activityID()
		let channels = try arguments.streamChannels()
		return .result(
			CoachReadout.streams(try await reach.reads.streams(of: id, channels: channels)))
	}

	static let fetchActivities = CoachTool.training(
		.intervalsFetchActivities,
		"Fetch recorded activity summaries for a date range. Each activity has an `id`, a local `start`, and the measurements intervals.icu recorded for it. Pass an `id` exactly as listed to `intervals_fetch_activity` or `intervals_fetch_streams`. Use only fields actually returned.",
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
	func readRange(today: CivilDate) throws(ToolInputError) -> ReadRange {
		let fields = objectFields
		guard let oldest = try Self.optionalDate(fields["oldest"], label: "oldest") else {
			throw ToolInputError(
				code: "invalid_input", details: "oldest is required. Use YYYY-MM-DD.")
		}
		let newest = try Self.optionalDate(fields["newest"], label: "newest")
		do throws(ReadRangeRefusal) {
			return try ReadRange(oldest: oldest, newest: newest, today: today)
		} catch {
			switch error {
			case .reversed(let oldest, let newest):
				throw ToolInputError(
					code: "invalid_range",
					details: "oldest (\(oldest)) is after newest (\(newest)). Swap the bounds.")
			case .tooWide(let days):
				let limit = IntervalsPolicy.listMaxRangeDays
				throw ToolInputError(
					code: "range_too_wide",
					details:
						"Range is \(days) days; the maximum is \(limit). Fetch the range in chunks of at most \(limit) days."
				)
			}
		}
	}

	func activityID() throws(ToolInputError) -> ActivityID {
		let value = objectFields["activityId"]
		if let raw = value?.stringValue, let id = ActivityID(rawValue: raw) {
			return id
		}
		if let number = value?.intValue(), let id = ActivityID(rawValue: String(number)) {
			return id
		}
		throw ToolInputError(
			code: "invalid_input",
			details: "activityId must be a positive integer, i-prefixed id, or lowercase 64-hex id."
		)
	}

	func streamChannels() throws(ToolInputError) -> StreamChannels {
		let requested: [String]?
		switch objectFields["types"] {
		case nil, .null?:
			requested = nil
		case .array(let entries)? where entries.allSatisfy({ $0.stringValue != nil }):
			requested = entries.compactMap(\.stringValue)
		default:
			throw ToolInputError(
				code: "invalid_input", details: "types must be a list of channel names.")
		}
		do throws(UnusableChannelName) {
			return try StreamChannels(requested: requested)
		} catch {
			throw ToolInputError(
				code: "invalid_input",
				details:
					"types entry \"\(error.name)\" is not one channel name. Give each channel as its own entry, never empty and with no comma."
			)
		}
	}

	private static func optionalDate(_ value: JSONValue?, label: String) throws(ToolInputError)
		-> CivilDate?
	{
		switch value {
		case nil, .null?:
			return nil
		case .string(let raw)?:
			guard let date = CivilDate(rawValue: raw) else {
				throw ToolInputError(
					code: "invalid_date",
					details: "\(raw) is not a real calendar date. Use YYYY-MM-DD.")
			}
			return date
		default:
			throw ToolInputError(
				code: "invalid_date",
				details: "\(label) is not a real calendar date. Use YYYY-MM-DD.")
		}
	}
}
