import Foundation

@testable import EnduragentCoach

enum LiveParkedQuestions {
	static func answers(_ reads: LiveRawReads) -> [ParkedAnswer] {
		let wellness = (reads.wellness?.arrayValue ?? []).map(\.objectFields)
		let listed = (reads.activities?.arrayValue ?? []).map(\.objectFields)
		let details = reads.details.map(\.objectFields).filter {
			!LiveReadAudit.isHiddenByStrava($0)
		}
		return [
			rampRate(wellness), hrv(wellness), intensity(listed + details),
			distance(listed, details), dateOfBirth(reads.profile?.objectFields ?? [:]),
			starts(listed + details), stravaHidden(listed, reads.details.map(\.objectFields)),
			laps(details), scales(listed + details), zoneTimes(details), streamTypes(reads),
		]
	}

	static func shape(_ text: String) -> String {
		String(text.map { $0.isNumber ? "d" : $0 })
	}

	static func range(_ values: [Double]) -> String {
		guard let low = values.min(), let high = values.max() else { return "no values" }
		return "\(number(low)) to \(number(high)) over \(values.count) values"
	}

	private static func number(_ value: Double) -> String {
		value == value.rounded() ? String(Int(value)) : String(format: "%.3f", value)
	}

	private static func numbers(_ rows: [[String: JSONValue]], _ key: String) -> [Double] {
		rows.compactMap { $0[key]?.numberValue }
	}

	private static func rampRate(_ rows: [[String: JSONValue]]) -> ParkedAnswer {
		let byDate = Dictionary(
			rows.compactMap { row in row["id"]?.stringValue.map { ($0, row) } },
			uniquingKeysWith: { first, _ in first })
		let differences: [Double] = rows.compactMap { row in
			guard let date = row["id"]?.stringValue.flatMap(CivilDate.init(rawValue:)),
				let ramp = row["rampRate"]?.numberValue, let fitness = row["ctl"]?.numberValue,
				let earlier = byDate[date.adding(days: -7).rawValue]?["ctl"]?.numberValue
			else { return nil }
			return abs(ramp - (fitness - earlier))
		}
		let consistent = !differences.isEmpty && differences.allSatisfy { $0 <= 1 }
		return ParkedAnswer(
			question: "Units and range of rampRate",
			evidence: [
				"rampRate: \(range(numbers(rows, "rampRate")))",
				"|rampRate − (Fitness − Fitness 7 days earlier)|: \(range(differences))",
				"App: decoded by WellnessField.rampRate, shown with unit \"Fitness per week\".",
			],
			decoding: [
				DecodingSite("Cycling/IntervalsRESTReads.swift", #"case .rampRate: "rampRate""#),
				DecodingSite(
					"Loop/CoachReadout.swift", #"case .rampRate: "Fitness per week""#),
			],
			verdict: differences.isEmpty
				? "not decidable from this window (no row with Fitness 7 days earlier)"
				: consistent
					? "matches: rampRate tracks the 7-day Fitness change"
					: "mismatch: rampRate is not the 7-day Fitness change; the unit needs review")
	}

	private static func hrv(_ rows: [[String: JSONValue]]) -> ParkedAnswer {
		let values = numbers(rows, "hrv")
		return ParkedAnswer(
			question: "Units and range of hrv",
			evidence: [
				"hrv: \(range(values))", "App: shown with unit \"ms\".",
			],
			decoding: [
				DecodingSite("Cycling/IntervalsRESTReads.swift", #"case .hrv: "hrv""#),
				DecodingSite("Loop/CoachReadout.swift", #"case .hrv: "ms""#),
			],
			verdict: values.isEmpty
				? "not observed: no HRV in the window"
				: values.allSatisfy { (5...300).contains($0) }
					? "matches: values sit in the millisecond range of rMSSD"
					: "mismatch: values outside 5 to 300 do not read as milliseconds")
	}

	private static func intensity(_ rows: [[String: JSONValue]]) -> ParkedAnswer {
		let values = numbers(rows, "icu_intensity")
		return ParkedAnswer(
			question: "Units and range of icu_intensity",
			evidence: [
				"icu_intensity: \(range(values))", "App: shown as intensity with unit \"%\".",
			],
			decoding: [
				DecodingSite(
					"Cycling/IntervalsRESTReads.swift", #"case .intensity: "icu_intensity""#),
				DecodingSite("Loop/CoachReadout.swift", #"case .intensity: "%""#),
			],
			verdict: values.isEmpty
				? "not observed"
				: (values.max() ?? 0) > 3
					? "matches: values are percentages"
					: "mismatch: values are fractions, but the app labels them %")
	}

	private static func distance(
		_ listed: [[String: JSONValue]], _ details: [[String: JSONValue]]
	) -> ParkedAnswer {
		let ratios: [Double] = (listed + details).compactMap { row in
			guard let distance = row["distance"]?.numberValue,
				let speed = row["average_speed"]?.numberValue,
				let time = row["moving_time"]?.numberValue, speed > 0, time > 0
			else { return nil }
			return distance / (speed * time)
		}
		let metres = !ratios.isEmpty && ratios.allSatisfy { (0.8...1.25).contains($0) }
		return ParkedAnswer(
			question: "Units and range of distance",
			evidence: [
				"distance: \(range(numbers(listed, "distance")))",
				"distance ÷ (average_speed × moving_time): \(range(ratios))",
				"App: shown with unit \"m\".",
			],
			decoding: [
				DecodingSite("Cycling/IntervalsRESTReads.swift", #"case .distance: "distance""#),
				DecodingSite("Loop/CoachReadout.swift", #"case .distance, .elevationGain: "m""#),
			],
			verdict: ratios.isEmpty
				? "not decidable: no row with distance, average_speed and moving_time"
				: metres ? "matches: distance is in metres" : "mismatch: distance is not in metres")
	}

	private static func dateOfBirth(_ athlete: [String: JSONValue]) -> ParkedAnswer {
		let birth = athlete["icu_date_of_birth"]
		let format = birth?.stringValue.map(shape) ?? birth.map(typeName) ?? "absent"
		return ParkedAnswer(
			question: "Format of icu_date_of_birth",
			evidence: [
				"icu_date_of_birth shape: \(format)",
				"App: parsed as a YYYY-MM-DD CivilDate and given to the coach as whole-year age.",
				"App: a null or absent date gives no age, so the coach is given no ageYears (the readout-profile fixture case \"nulls have no key and zeros stay\").",
			],
			decoding: [
				DecodingSite("Cycling/IntervalsRESTReads.swift", "func wholeYears(since birth"),
				DecodingSite("Loop/CoachReadout.swift", "if let age = profile.ageYears"),
			],
			verdict: format == "dddd-dd-dd"
				? "matches"
				: ["absent", "null"].contains(format) ? "not supplied by this account" : "mismatch")
	}

	private static func starts(_ rows: [[String: JSONValue]]) -> ParkedAnswer {
		let shapes = Set(rows.compactMap { $0["start_date_local"]?.stringValue.map(shape) })
		let readable: Set<String> = ["dddd-dd-ddTdd:dd:dd", "dddd-dd-dd"]
		return ParkedAnswer(
			question: "Format of start_date_local",
			evidence: [
				"shapes: \(shapes.sorted().joined(separator: ", "))",
				"App: read as a local wall-clock start with no offset, or a date alone.",
			],
			decoding: [
				DecodingSite(
					"Cycling/IntervalsRESTReads.swift",
					#"fields["start_date_local"]?.stringValue.flatMap(localStart)"#),
				DecodingSite("Cycling/IntervalsRESTReads.swift", "func localStart(_ wire: String)"),
			],
			verdict: shapes.isEmpty
				? "not observed" : shapes.isSubset(of: readable) ? "matches" : "mismatch")
	}

	private static func stravaHidden(
		_ listed: [[String: JSONValue]], _ details: [[String: JSONValue]]
	) -> ParkedAnswer {
		let rows = listed.filter(LiveReadAudit.isHiddenByStrava)
		let shapes = Set(rows.map { $0.keys.sorted().joined(separator: ", ") })
		let detailShapes = Set(
			details.filter(LiveReadAudit.isHiddenByStrava).map {
				$0.keys.sorted().joined(separator: ", ")
			})
		return ParkedAnswer(
			question: "Shape of a Strava-hidden row",
			evidence: [
				"hidden list rows: \(rows.count)",
				"list row keys: \(shapes.sorted().joined(separator: " | "))",
				"detail answer keys: \(detailShapes.sorted().joined(separator: " | "))",
				"App: a row with source STRAVA that lacks type, moving_time or elapsed_time is hidden.",
			],
			decoding: [
				DecodingSite(
					"Cycling/Activities.swift", "if source == IntervalsPolicy.stravaSource")
			],
			verdict: rows.isEmpty
				? "not observed: this account has no Strava-hidden activity in 30 days"
				: "matches: every such row has source STRAVA and lacks a time or type")
	}

	private static func laps(_ details: [[String: JSONValue]]) -> ParkedAnswer {
		let answers = details.map { detail -> String in
			switch detail["icu_intervals"] {
			case nil: "no icu_intervals key"
			case .null?: "icu_intervals null"
			case .array(let laps)?: "icu_intervals with \(laps.count) entries"
			case let other?: "icu_intervals as \(typeName(other))"
			}
		}
		let supplied = answers.contains { $0.hasPrefix("icu_intervals with") }
		return ParkedAnswer(
			question: "Does intervals=true return icu_intervals",
			evidence: answers.enumerated().map { "detail \($0.offset + 1): \($0.element)" }
				+ ["App: asks GET /activity/{id}?intervals=true and reads icu_intervals as laps."],
			decoding: [
				DecodingSite(
					"Cycling/IntervalsRESTReads.swift",
					#"URLQueryItem(name: "intervals", value: "true")"#),
				DecodingSite(
					"Cycling/IntervalsRESTReads.swift", #"Self.laps(from: fields["icu_intervals"])"#
				),
			],
			verdict: details.isEmpty
				? "not observed: no detail was read"
				: supplied
					? "matches: laps arrive with intervals=true" : "mismatch: no laps arrived")
	}

	private static func scales(_ rows: [[String: JSONValue]]) -> ParkedAnswer {
		let feel = Set(numbers(rows, "feel")).sorted().map(number)
		let rpe = Set(numbers(rows, "icu_rpe")).sorted().map(number)
		return ParkedAnswer(
			question: "Scales of feel and icu_rpe",
			evidence: [
				"feel values seen: \(feel.isEmpty ? "none" : feel.joined(separator: ", "))",
				"icu_rpe values seen: \(rpe.isEmpty ? "none" : rpe.joined(separator: ", "))",
				"App: both passed through as plain numbers with no unit and no scale.",
			],
			decoding: [
				DecodingSite(
					"Cycling/IntervalsRESTReads.swift", #"case .perceivedExertion: "icu_rpe""#),
				DecodingSite("Cycling/IntervalsRESTReads.swift", #"case .feel: "feel""#),
				DecodingSite(
					"Loop/CoachReadout.swift",
					"case .perceivedExertion, .feel, .variabilityIndex"),
			],
			verdict: feel.isEmpty && rpe.isEmpty
				? "not observed: the athlete recorded neither"
				: "passed through unchanged; the scale is not stated to the coach")
	}

	private static func zoneTimes(_ details: [[String: JSONValue]]) -> ParkedAnswer {
		let power = details.compactMap { $0["icu_zone_times"]?.arrayValue }.flatMap { $0 }
		let heart = details.compactMap { $0["icu_hr_zone_times"]?.arrayValue }.flatMap { $0 }
		let powerShapes = Set(power.map(typeName))
		let heartShapes = Set(heart.map(typeName))
		let zones = Set(power.compactMap { $0.objectFields["id"]?.stringValue }).sorted()
		let readable =
			powerShapes.allSatisfy {
				$0.hasPrefix("object{") && $0.contains("id") && $0.contains("secs")
			}
			&& heartShapes.isSubset(of: ["number"])
		return ParkedAnswer(
			question: "Shape of icu_zone_times",
			evidence: [
				"icu_zone_times entries: \(powerShapes.sorted().joined(separator: " | "))",
				"zone ids: \(zones.joined(separator: ", "))",
				"icu_hr_zone_times entries: \(heartShapes.sorted().joined(separator: " | "))",
				"App: power entries read as {id, secs}; heart-rate entries as whole seconds.",
			],
			decoding: [
				DecodingSite(
					"Cycling/IntervalsRESTReads.swift",
					#"powerZoneSeconds: (fields["icu_zone_times"]"#),
				DecodingSite(
					"Cycling/IntervalsRESTReads.swift", "func heartRateZoneSeconds(_ wire"),
			],
			verdict: power.isEmpty && heart.isEmpty
				? "not observed" : readable ? "matches" : "mismatch")
	}

	private static func streamTypes(_ reads: LiveRawReads) -> ParkedAnswer {
		let returned = channels(in: reads.streams?.json)
		let asked = Set(reads.askedChannels)
		let joined =
			returned.count > 1 && returned.isSubset(of: asked.union(["time"]))
			? "matches: intervals.icu honours comma-joined types"
			: "check: intervals.icu returned \(returned.count) of \(asked.count) asked channels"
		return ParkedAnswer(
			question: "Stream types: comma-joined, and an unknown channel",
			evidence: [
				"query sent: \(reads.streams?.query ?? "none")",
				"asked: \(reads.askedChannels.joined(separator: ", "))",
				"returned: \(returned.sorted().joined(separator: ", "))",
				"unknown channel: \(unknownChannel(reads))",
				"App: joins channel names with commas in one types parameter. When intervals.icu answers 422 \"Invalid stream type [name]\" for a name it was asked, the read drops that name and asks again, at most \(IntervalsPolicy.streamRequestLimit) requests. The coach is given each rejected name under unknown, each name the cap left unasked under unread, and each accepted name with no samples under unanswered.",
			],
			decoding: [
				DecodingSite("Cycling/IntervalsRESTStreams.swift", #"URLQueryItem(name: "types""#),
				DecodingSite(
					"Cycling/IntervalsRESTStreams.swift",
					"private static func rejectedStreamType(in answer"),
				DecodingSite("Cycling/Activities.swift", "self.unknown = missing.filter"),
				DecodingSite("Cycling/Activities.swift", "self.unanswered = missing.filter"),
			],
			verdict: reads.streams == nil
				? "not observed: no ride in 30 days" : "\(joined); \(unknownVerdict(reads))")
	}

	private static func unknownVerdict(_ reads: LiveRawReads) -> String {
		let probe = reads.unknownChannelName
		guard let outcome = reads.unknownChannel else { return "unknown channel: not read" }
		guard let given = outcome.given else {
			return "mismatch: the app's read threw on the unknown channel \(probe)"
		}
		let lists = streamLists(given)
		return lists["unknown"]?.contains(probe) == true
			? "matches: the read answered and the coach is given \(probe) under unknown"
			: "mismatch: the read answered but the coach is given \(probe) under \(lists.filter { $0.value.contains(probe) }.keys.sorted().first ?? "no list")"
	}

	private static func unknownChannel(_ reads: LiveRawReads) -> String {
		guard let outcome = reads.unknownChannel else { return "not read" }
		let answers = outcome.responses.map { response in
			guard response.answered else {
				return "HTTP \(response.status) to \(response.request): \(response.excerpt)"
			}
			let returned = channels(in: response.json)
			return
				"HTTP \(response.status) to \(response.request): \(reads.unknownChannelName) \(returned.contains(reads.unknownChannelName) ? "returned" : "absent"); channels returned: \(returned.sorted().joined(separator: ", "))"
		}
		let given = outcome.given.map { given in
			let lists = streamLists(given)
			return "the coach is given "
				+ (["channels": Set((given.objectFields["channels"]?.objectFields ?? [:]).keys)]
					.merging(lists) { first, _ in first }
					.filter { !$0.value.isEmpty }
					.sorted { $0.key < $1.key }
					.map { "\($0.key) \($0.value.sorted().joined(separator: ", "))" }
					.joined(separator: "; "))
		}
		return
			([outcome.threw ? "the app's read threw" : "the app's read answered"]
			+ (answers.isEmpty ? ["no response was captured"] : answers)
			+ (given.map { [$0] } ?? []))
			.joined(separator: "; ")
	}

	static func streamLists(_ given: JSONValue) -> [String: Set<String>] {
		Dictionary(
			uniqueKeysWithValues: ["unanswered", "unknown", "unread"].map { key in
				(key, Set((given.objectFields[key]?.arrayValue ?? []).compactMap(\.stringValue)))
			})
	}

	private static func channels(in json: JSONValue?) -> Set<String> {
		switch json {
		case .array(let entries)?: Set(entries.compactMap { $0.objectFields["type"]?.stringValue })
		case .object(let fields)?: Set(fields.keys)
		default: []
		}
	}

	static func typeName(_ value: JSONValue) -> String {
		switch value {
		case .null: "null"
		case .bool: "bool"
		case .number: "number"
		case .string: "string"
		case .array(let entries): "array[\(entries.count)]"
		case .object(let fields):
			"object{"
				+ fields.keys.sorted().map { "\($0): \(typeName(fields[$0] ?? .null))" }
				.joined(separator: ", ") + "}"
		}
	}
}
