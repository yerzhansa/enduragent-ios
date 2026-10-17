import Foundation

@testable import EnduragentCoach

struct LiveCalendarAdd: Sendable, Equatable {
	let key: String
	let identity: CalendarWriteID
	let payload: CalendarPayload

	var externalID: String { identity.externalID }
	var write: CalendarWrite { .create(payload, identity: identity) }
	var body: JSONValue { payload.requestBody(identity) }
}

struct LiveCalendarMove: Sendable, Equatable {
	let add: LiveCalendarAdd
	let days: Int
	let patch: WorkoutPatch

	var destination: CivilDate { add.payload.date.adding(days: days) }

	var staysInWindow: Bool {
		get throws(ReadRangeRefusal) {
			try LiveSeedCalendar.window(around: add.payload.date).contains(destination)
		}
	}
}

struct LiveDeskPlan: Sendable {
	let ride: LiveCalendarAdd
	let strength: LiveCalendarAdd
	let edited: LiveCalendarAdd
	let deleted: LiveCalendarAdd
	let kept: LiveCalendarAdd
	let edit: WorkoutPatch

	var adds: [LiveCalendarAdd] { [ride, strength, edited, deleted, kept] }
}

struct LiveCalendarPlan: Sendable {
	static let daysAhead = 40
	static let unknownCategory = "ENDURAGENT_UNKNOWN_CATEGORY"
	static let ride = JSONValue.object([
		"name": .string("\(LiveSeedPlan.namePrefix) live-calendar threshold 3x2"),
		"steps": .array([
			step("warmup", minutes: 2, low: 50, high: 60),
			.object([
				"type": .string("set"), "repeat": .number(3),
				"interval": .object([
					"type": .string("interval"), "label": .string("Threshold"),
					"duration": minutes(2), "power": percent(low: 95, high: 105),
				]),
				"recovery": .object([
					"type": .string("recovery"), "duration": minutes(1), "power": percent(50),
				]),
			]),
			step("steady", minutes: 2, power: 65),
			step("cooldown", minutes: 2, power: 50),
		]),
	])
	static let editedSteps = JSONValue.object([
		"steps": .array([
			step("warmup", minutes: 5, low: 50, high: 65),
			step("steady", minutes: 20, power: 70),
			step("cooldown", minutes: 5, power: 50),
		])
	])

	let today: CivilDate
	let first: CivilDate
	let ride: LiveCalendarAdd
	let strength: LiveCalendarAdd
	let edited: LiveCalendarAdd
	let movedNear: LiveCalendarMove
	let movedFar: LiveCalendarMove
	let refused: LiveCalendarAdd
	let lost: LiveCalendarAdd
	let edits: [(field: String, patch: WorkoutPatch)]
	let lostEdit: WorkoutPatch
	let desk: LiveDeskPlan

	var adds: [LiveCalendarAdd] {
		[ride, strength, edited, movedNear.add, movedFar.add, refused, lost] + desk.adds
	}

	init(today: CivilDate, identities: () -> CalendarWriteID = { CalendarWriteID() }) throws {
		self.today = today
		let first = today.adding(days: Self.daysAhead)
		self.first = first
		func ride(_ key: String, on date: CivilDate, load: Int) throws -> LiveCalendarAdd {
			LiveCalendarAdd(
				key: key, identity: identities(),
				payload: try CalendarPayload.ride(
					.object([
						"date": .string(date.rawValue), "workout": Self.ride,
						"trainingLoad": .number(Double(load)),
					]), today: today))
		}
		func move(_ add: LiveCalendarAdd, days: Int) throws -> LiveCalendarMove {
			let destination = add.payload.date.adding(days: days)
			return LiveCalendarMove(
				add: add, days: days,
				patch: try WorkoutPatch.parse(
					.object(["date": .string(destination.rawValue)]), today: today))
		}
		self.ride = try ride("ride", on: first, load: 21)
		func strength(_ key: String, on date: CivilDate) throws -> LiveCalendarAdd {
			LiveCalendarAdd(
				key: key, identity: identities(),
				payload: try CalendarPayload.strength(
					.object([
						"date": .string(date.rawValue),
						"name": .string("\(LiveSeedPlan.namePrefix) live-calendar \(key)"),
						"durationMinutes": .number(37.5),
						"effort": .string("Moderate, RPE 6"),
						"description": .string("3 x 10 goblet squats\n3 x 8 single-leg deadlifts"),
						"trainingLoad": .number(24),
					]), today: today))
		}
		self.strength = try strength("strength", on: first.adding(days: 1))
		self.edited = try ride("edited", on: first.adding(days: 2), load: 22)
		self.movedNear = try move(ride("moved-30", on: first.adding(days: 3), load: 23), days: 30)
		self.movedFar = try move(ride("moved-200", on: first.adding(days: 4), load: 24), days: 200)
		self.refused = try ride("refused", on: first.adding(days: 5), load: 25)
		self.lost = try ride("lost", on: first.adding(days: 6), load: 26)
		self.lostEdit = try WorkoutPatch.parse(
			.object(["structure": Self.editedSteps, "trainingLoad": .number(34)]), today: today)
		self.desk = LiveDeskPlan(
			ride: try ride("desk-ride", on: first.adding(days: 7), load: 27),
			strength: try strength("desk-strength", on: first.adding(days: 8)),
			edited: try ride("desk-edited", on: first.adding(days: 8), load: 28),
			deleted: try ride("desk-deleted", on: first.adding(days: 9), load: 29),
			kept: try ride("desk-kept", on: first.adding(days: 9), load: 30),
			edit: try WorkoutPatch.parse(.object(["durationSeconds": .number(1_800)]), today: today)
		)
		let editDate = first.adding(days: 2)
		let fields: [(String, JSONValue)] = [
			("date", .string(editDate.adding(days: 1).rawValue)),
			("name", .string("\(LiveSeedPlan.namePrefix) live-calendar edited name")),
			("trainingLoad", .number(33)),
			("durationSeconds", .number(1_500)),
			("description", .string("Steady endurance by feel, no structure.")),
			("structure", Self.editedSteps),
		]
		self.edits = try fields.map { field, value in
			(field, try WorkoutPatch.parse(.object([field: value]), today: today))
		}
	}

	static func withUnknownCategory(_ body: Data) -> Data {
		guard let text = String(data: body, encoding: .utf8) else { return body }
		return Data(
			text.replacingOccurrences(
				of: #""category":"WORKOUT""#, with: #""category":"\#(unknownCategory)""#
			).utf8)
	}

	private static func minutes(_ value: Int) -> JSONValue {
		.object(["value": .number(Double(value)), "unit": .string("minutes")])
	}

	private static func percent(_ value: Int) -> JSONValue {
		.object(["kind": .string("percent_ftp"), "value": .number(Double(value))])
	}

	private static func percent(low: Int, high: Int) -> JSONValue {
		.object([
			"kind": .string("percent_ftp"), "low": .number(Double(low)),
			"high": .number(Double(high)),
		])
	}

	private static func step(_ type: String, minutes value: Int, power: Int) -> JSONValue {
		.object([
			"type": .string(type), "duration": minutes(value), "power": percent(power),
		])
	}

	private static func step(_ type: String, minutes value: Int, low: Int, high: Int)
		-> JSONValue
	{
		.object([
			"type": .string(type), "duration": minutes(value),
			"power": percent(low: low, high: high),
		])
	}
}
