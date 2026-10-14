import Foundation

enum CoachReadout {
	static func profile(_ profile: AthleteProfile) -> JSONValue {
		var fields: [String: JSONValue] = [
			"id": .string(profile.id),
			"name": .string(profile.name),
		]
		var units: [String: JSONValue] = [:]
		switch profile.ftp {
		case .absent:
			break
		case .usable(let watts):
			fields["ftp"] = .number(watts.value)
		case .implausible(let reported):
			if let reported { fields["ftp"] = .number(reported) }
			fields["ftpUsable"] = .bool(false)
			fields["ftpNotice"] = .string(PromptStaticBlocks.snapshotQualitativeFTP)
		}
		if fields["ftp"] != nil { units["ftp"] = .string("W") }
		write(profile.readings, to: &fields, units: &units)
		if let sex = profile.sex { fields["sex"] = .string(sex) }
		if let age = profile.ageYears { fields["ageYears"] = .number(Double(age)) }
		if !profile.settingsSports.isEmpty {
			fields["sports"] = .array(profile.settingsSports.map(JSONValue.string))
		}
		for (key, zones, unit) in [
			("powerZones", profile.powerZones, "% of FTP"),
			("heartRateZones", profile.heartRateZones, "bpm"),
		] where !zones.isEmpty {
			fields[key] = ladder(zones)
			units[key] = .string(unit)
		}
		if !units.isEmpty { fields["units"] = .object(units) }
		return .object(fields)
	}

	static func wellness(_ days: [WellnessDay], in range: ReadRange) -> JSONValue {
		var units: [String: JSONValue] = [:]
		let rows = days.sorted { $0.date < $1.date }.map { day in
			var fields: [String: JSONValue] = ["date": .string(day.date.rawValue)]
			write(day.readings, to: &fields, units: &units)
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
		"\(hidden) of \(total) activities are hidden by Strava, so they aren’t included. \(stravaGuidance)"
	}

	private static let stravaGuidance =
		"Strava does not allow third-party AI tools to use data from its API. For future rides, connect your recording source directly to intervals.icu and keep Strava connected. For past rides, use Import All Strava Data in intervals.icu settings; it requires an intervals.icu supporter subscription."

	static func activity(_ read: ActivityDetailRead, asked id: ActivityID) -> JSONValue {
		switch read {
		case .found(let detail):
			found(detail)
		case .notFound:
			unread(
				id, "activity_not_found",
				"intervals.icu has no activity \(id.rawValue). Pass an id exactly as intervals_fetch_activities listed it."
			)
		case .hiddenByStrava:
			unread(
				id, "activity_hidden_by_strava",
				"Activity \(id.rawValue) is hidden by Strava, so it can’t be read. \(stravaGuidance)"
			)
		}
	}

	static func activityUnread(_ id: ActivityID, _ error: IntervalsError) -> JSONValue {
		unread(
			id, "activity_detail_unavailable",
			"The detail of activity \(id.rawValue) could not be read. The read failed: the activity is not empty or missing, and no other activity stands in for it. Cause: \(error.details)",
			cause: error.code)
	}

	static func streams(_ summary: StreamSummary) -> JSONValue {
		var result: [String: JSONValue] = [
			"sampleCount": .number(Double(summary.sampleCount)),
			"channels": .object(
				summary.channels.mapValues { channel in
					.object([
						"min": .number(channel.min), "max": .number(channel.max),
						"mean": .number(channel.mean),
					])
				}),
		]
		for (key, names) in [
			("unanswered", summary.unanswered), ("unknown", summary.unknown),
			("unread", summary.unread),
		] where !names.isEmpty {
			result[key] = .array(names.map(JSONValue.string))
		}
		return .object(result)
	}

	private static func ladder(_ zones: [TrainingZone]) -> JSONValue {
		.array(
			zones.map { zone in
				var fields: [String: JSONValue] = ["upTo": .number(zone.upperBound)]
				if let name = zone.name { fields["name"] = .string(name) }
				return .object(fields)
			})
	}

	private static func unread(
		_ id: ActivityID, _ code: String, _ details: String, cause: String? = nil
	) -> JSONValue {
		var fields: [String: JSONValue] = [
			"error": .string(code),
			"activityId": .string(id.rawValue),
			"details": .string(details),
		]
		if let cause { fields["cause"] = .string(cause) }
		return .object(fields)
	}

	private static func found(_ detail: ActivityDetail) -> JSONValue {
		var units: [String: JSONValue] = [:]
		var activity = row(of: detail.activity, units: &units).objectFields
		let extras = detail.extras
		write(extras.readings, to: &activity, units: &units)
		if let notes = extras.notes { activity["notes"] = .string(notes) }
		if let indoor = extras.indoor { activity["indoor"] = .bool(indoor) }
		if !extras.powerZoneSeconds.isEmpty {
			activity["powerZoneSeconds"] = .array(
				extras.powerZoneSeconds.map {
					.object(["zone": .string($0.zone), "seconds": .number(Double($0.seconds))])
				})
			units["powerZoneSeconds"] = .string("s")
		}
		if !extras.heartRateZoneSeconds.isEmpty {
			activity["heartRateZoneSeconds"] = .array(
				extras.heartRateZoneSeconds.map { .number(Double($0)) })
			units["heartRateZoneSeconds"] = .string("s")
		}
		switch detail.laps {
		case .notSupplied:
			return detailResult(activity, ["lapsSupplied": .bool(false)], units: units)
		case .recorded(let laps):
			var lapUnits = units
			let rows = laps.map { row(of: $0, units: &lapUnits) }
			let shown = detailResult(activity, ["laps": .array(rows)], units: lapUnits)
			if ToolResultCap.admits(shown) { return shown }
			let lapless = detailResult(
				activity,
				[
					"lapCount": .number(Double(laps.count)),
					"lapsOmitted": .string(lapsOmitted(laps.count)),
				], units: units)
			return ToolResultCap.admits(lapless) ? lapless : shown
		}
	}

	private static func lapsOmitted(_ count: Int) -> String {
		"intervals.icu supplied \(count) laps, more than one tool result can hold, so the laps are left out. The activity's own measurements are complete; lap data is unavailable for this read."
	}

	private static func detailResult(
		_ activity: [String: JSONValue], _ laps: [String: JSONValue],
		units: [String: JSONValue]
	) -> JSONValue {
		var fields = laps
		fields["activity"] = .object(activity)
		if !units.isEmpty { fields["units"] = .object(units) }
		return .object(fields)
	}

	private static func row(of lap: ActivityLap, units: inout [String: JSONValue]) -> JSONValue {
		var fields: [String: JSONValue] = ["number": .number(Double(lap.number))]
		if let label = lap.label { fields["label"] = .string(label) }
		if let kind = lap.kind { fields["kind"] = .string(kind) }
		write(lap.readings, to: &fields, units: &units)
		return .object(fields)
	}

	private static func row(of activity: Activity, units: inout [String: JSONValue]) -> JSONValue {
		var fields: [String: JSONValue] = [
			"id": .string(activity.id.rawValue),
			"start": .string(activity.start.readout),
		]
		if let name = activity.name { fields["name"] = .string(name) }
		if let sport = activity.sport { fields["sport"] = .string(sport) }
		write(activity.readings, to: &fields, units: &units)
		return .object(fields)
	}

	private static func write<Field: ReadoutMeasurement>(
		_ readings: Readings<Field>, to fields: inout [String: JSONValue],
		units: inout [String: JSONValue]
	) {
		for field in Field.allCases {
			guard let value = readings[field] else { continue }
			fields[field.rawValue] = .number(value)
			if let unit = field.unit { units[field.rawValue] = .string(unit) }
		}
	}
}

protocol ReadoutMeasurement: RawRepresentable<String>, Hashable, Sendable, CaseIterable {
	var unit: String? { get }
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

extension ActivityField: ReadoutMeasurement {
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

extension ActivityDetailField: ReadoutMeasurement {
	var unit: String? {
		switch self {
		case .perceivedExertion, .feel, .variabilityIndex, .efficiencyFactor: nil
		case .averageCadence: "rpm"
		case .averageSpeed, .maxSpeed: "m/s"
		case .calories: "kcal"
		case .work: "J"
		case .decoupling: "%"
		}
	}
}

extension ProfileField: ReadoutMeasurement {
	var unit: String? {
		switch self {
		case .lthr, .maxHeartRate, .restingHeartRate: "bpm"
		case .weight: "kg"
		case .indoorFTP, .maxPower: "W"
		case .wPrime: "J"
		case .sweetSpotMin, .sweetSpotMax: "% of FTP"
		}
	}
}

extension WellnessField: ReadoutMeasurement {
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
