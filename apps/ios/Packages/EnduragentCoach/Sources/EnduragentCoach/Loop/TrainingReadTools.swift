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
		return .result(CoachReadout.wellness(try await reach.reads.wellness(in: range)))
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
				"days": ToolParameters.integer(
					"Inclusive day count ending today in the athlete time zone"
				),
			],
			required: []
		)
	) { arguments, reach in
		let range = try arguments.readRange(today: reach.local.today)
		let rows = try await reach.calendar.fetchActivities(
			oldest: range.oldest, newest: range.newest)
		return .result(CoachReadout.activities(rows))
	}
}

enum CoachReadout {
	static func profile(_ profile: AthleteProfile) -> JSONValue {
		var fields: [String: JSONValue] = [
			"id": .string(profile.id),
			"name": .string(profile.name),
		]
		switch profile.ftp {
		case .usable(let watts):
			fields["ftp"] = .number(watts.value)
		case .implausible(let reported?):
			fields["ftp"] = .number(reported)
		case .absent, .implausible(nil):
			break
		}
		return .object(fields)
	}

	static func wellness(_ days: [WellnessDay]) -> JSONValue {
		.array(
			days.map { day in
				var fields: [String: JSONValue] = ["date": .string(day.date.rawValue)]
				if let fitness = day.fitness { fields["fitness"] = .number(fitness) }
				if let fatigue = day.fatigue { fields["fatigue"] = .number(fatigue) }
				if let form = day.form { fields["form"] = .number(form) }
				return .object(fields)
			})
	}

	static func activities(_ rows: [ActivitySummary]) -> JSONValue {
		.array(
			rows.map { row in
				var fields: [String: JSONValue] = [
					"name": .string(row.name),
					"date": .string(row.date.rawValue),
					"durationS": .number(Double(row.durationS)),
				]
				if let load = row.trainingLoad {
					fields["trainingLoad"] = .number(Double(load))
				}
				return .object(fields)
			})
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
		if let value = fields["days"] {
			guard let days = value.intValue() else {
				throw IntervalsError(
					code: "invalid_input", details: "days must be a positive integer.")
			}
			return try ReadRange(endingOn: today, days: days)
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
