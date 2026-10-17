import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

enum PreflightFixture {
	static let today: CivilDate = "1998-09-08"
	static let connection = ConnectionID()
	static let account = TrainingAccount.intervals(
		connection: connection, athlete: IntervalsAthleteID(rawValue: "i1001"))
	static let otherAthlete = TrainingAccount.intervals(
		connection: ConnectionID(), athlete: IntervalsAthleteID(rawValue: "i2002"))
	static let rideIdentity = CalendarWriteID()
	static let stepsDescription = "Warmup\n- 10m 60%\nMain set\n- 3x15m 90%"
	static let parsedSteps = JSONValue.array([
		.object([
			"duration": .number(600),
			"power": .object(["units": .string("%ftp"), "value": .number(60)]),
		]),
		.object([
			"reps": .number(3),
			"steps": .array([
				.object([
					"duration": .number(900),
					"power": .object(["units": .string("%ftp"), "value": .number(90)]),
				])
			]),
		]),
	])

	static func workout(
		_ id: Int, on date: CivilDate, name: String = "Endurance", minutes: Int = 60,
		load: Int = 50, description: String? = "Steady ride", document: JSONValue? = nil
	) -> CalendarEvent {
		CalendarEvent(
			description: description, type: "Ride", id: EventID(rawValue: id),
			startDateLocal: "\(date.rawValue)T00:00:00", name: name, category: "WORKOUT",
			externalId: nil, uid: nil, tags: [IntervalsPolicy.coachTag], coachCreated: true,
			movingTime: minutes * 60, trainingLoad: load, workoutDocument: document)
	}

	static func stepped(_ id: Int, on date: CivilDate, load: Int = 61) -> CalendarEvent {
		workout(
			id, on: date, name: "Sweet spot", minutes: 55, load: load,
			description: stepsDescription,
			document: derivedDocument(steps: parsedSteps, averageWatts: 180))
	}

	static func derivedDocument(steps: JSONValue, averageWatts: Int) -> JSONValue {
		.object([
			"duration": .number(3300), "steps": steps,
			"average_watts": .number(Double(averageWatts)),
			"normalized_power": .number(Double(averageWatts + 6)), "options": .object([:]),
			"zoneTimes": .array([
				.object([
					"id": .string("Z1"), "maxWatts": .number(Double(averageWatts - 40)),
					"secs": .number(600),
				])
			]),
			"description": .string(stepsDescription),
		])
	}

	static func ride(on date: CivilDate, identity: CalendarWriteID = rideIdentity)
		-> ChangeAction
	{
		.add(
			AddedWorkout(
				payload: CalendarPayload(
					date: date, type: .ride, name: "Tempo ride",
					description: "Warmup\n- 10m 60%\nMain set\n- 3x10m 85%", movingTime: 3000,
					trainingLoad: 55, authoredSteps: nil),
				identity: identity))
	}

	static func carrying(_ identity: CalendarWriteID, _ id: Int, on date: CivilDate)
		-> CalendarEvent
	{
		var event = workout(id, on: date, name: "Tempo ride", minutes: 50, load: 55)
		event.externalId = identity.externalID
		event.uid = identity.uid
		return event
	}

	static func edit(_ event: CalendarEvent, _ patch: WorkoutPatch) throws -> ChangeAction {
		.edit(EditedWorkout(target: .reviewed(event.id, try event.snapshot), patch: patch))
	}

	static func delete(_ event: CalendarEvent) throws -> ChangeAction {
		.delete(DeletedWorkout(target: .reviewed(event.id, try event.snapshot)))
	}

	static func patch(
		date: CivilDate? = nil, minutes: Int? = nil, description: String? = nil,
		load: Int? = nil
	) -> WorkoutPatch {
		WorkoutPatch(
			date: date, name: nil, durationSeconds: minutes.map { $0 * 60 },
			description: description, trainingLoad: load, workoutDocument: nil, authoredSteps: nil)
	}

	static func review(
		_ actions: [ChangeAction], finished: [FinishedChange] = [],
		account: TrainingAccount = account
	) throws -> WorkoutReview {
		let remaining = actions.enumerated().map { index, action in
			ReviewChange(
				id: reviewChange(600 + index), position: finished.count + index, action: action)
		}
		var document = try #require(
			try JSONSerialization.jsonObject(with: fixtureData("workout-review-approval"))
				as? [String: Any])
		document["account"] = account.storedValue
		document["kept"] = [Any]()
		document["remaining"] = try remaining.map { try jsonObject(ChangeDocument($0)) }
		document["finished"] = try finished.map { try jsonObject(FinishedDocument($0)) }
		return try WorkoutReviewPayload.decode(
			try JSONSerialization.data(withJSONObject: document))
	}

	static func change(_ number: Int) -> ChangeID {
		reviewChange(600 + number)
	}

	private static func jsonObject(_ value: some Encodable) throws -> Any {
		try JSONSerialization.jsonObject(with: try JSONEncoder().encode(value))
	}
}

extension PreflightVerdict {
	enum Kind: String, Sendable, CustomTestStringConvertible {
		case clear, changed, unchecked, accountChanged, trainingNotConnected, cannotVerify
		case pastProtected, coachOnly, workoutOnly, reviewedBeforeUpgrade, turnStopping

		var testDescription: String { rawValue }
	}

	var kind: Kind {
		switch self {
		case .clear: .clear
		case .changed: .changed
		case .unchecked: .unchecked
		case .blocked(let block):
			switch block {
			case .accountChanged: .accountChanged
			case .trainingNotConnected: .trainingNotConnected
			case .cannotVerify: .cannotVerify
			case .pastProtected: .pastProtected
			case .coachOnly: .coachOnly
			case .workoutOnly: .workoutOnly
			case .reviewedBeforeUpgrade: .reviewedBeforeUpgrade
			case .turnStopping: .turnStopping
			}
		}
	}

	var differences: [TargetDifference]? {
		guard case .changed(_, _, let differences) = self else { return nil }
		return differences
	}

	var seen: [ChangeID: EventID]? {
		guard case .clear(_, let seen) = self else { return nil }
		return seen
	}

	var kept: [KeptWorkout]? {
		switch self {
		case .clear(let kept, _), .changed(_, let kept, _): kept
		case .blocked, .unchecked: nil
		}
	}
}
