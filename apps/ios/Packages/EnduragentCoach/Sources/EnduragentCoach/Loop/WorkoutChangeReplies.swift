import Foundation

extension PreparationReply {
	var json: JSONValue {
		switch self {
		case .drafted(let changes, _):
			.object([
				"kind": .string("prepared"),
				"changeCount": .number(Double(changes)),
				"details": .string(
					"Nothing was written to the calendar. The athlete can approve the review after this reply ends."
				),
			])
		case .incomplete:
			.object([
				"kind": .string("incomplete"),
				"details": .string(
					"No review will be shown. Tell the athlete the change could not be prepared."),
			])
		case .refused(let refusal):
			.object(["error": .string(refusal.code), "details": .string(refusal.details)])
		}
	}
}

extension PreparationRefusal {
	fileprivate var code: String {
		switch self {
		case .reviewRunning: "review_running"
		case .reviewUnconfirmed: "review_unconfirmed"
		case .reviewWaiting: "review_waiting"
		case .staleBase: "stale_base"
		case .unknownItem: "unknown_item"
		case .twoActionsOnOneWorkout: "two_actions_on_one_workout"
		case .ineligible(_, .notAWorkout): "not_a_workout"
		case .ineligible(_, .notCoachCreated): "not_coach_created"
		case .ineligible(_, .pastWorkout): "past_workout_protected"
		case .ineligible(_, .pastDate): "past_workout_destination"
		case .pastDate: "past_date_refused"
		case .targetUnreadable: "target_unreadable"
		case .keptUnreadable: "calendar_unreadable"
		case .storageUnavailable: "storage_unavailable"
		}
	}

	fileprivate var details: String {
		switch self {
		case .reviewRunning:
			"An approved review is being written to the calendar. Prepare new changes after it ends."
		case .reviewUnconfirmed:
			"A change of the last review is unconfirmed. The athlete must check it again or cancel it first."
		case .reviewWaiting(let base):
			"A review already waits for approval. Read it with get_pending_workout_changes and use revise or replace with base setId \(base.review.ulid.rawValue) and revision \(base.revision.rawValue)."
		case .staleBase:
			"The pending review changed. Read it again with get_pending_workout_changes before preparing a revision."
		case .unknownItem(let id):
			"No pending item has id \(id.ulid.rawValue). Item ids come from get_pending_workout_changes and differ from calendar event ids."
		case .twoActionsOnOneWorkout(let event):
			"Event \(event.rawValue) appears more than once. A workout can have only one action in a review."
		case .ineligible(let event, .notAWorkout):
			"Event \(event.rawValue) is not a scheduled workout. Races, notes and other entries cannot be changed by the coach."
		case .ineligible(let event, .notCoachCreated):
			"Event \(event.rawValue) was not created by this coach. The athlete can change it on intervals.icu."
		case .ineligible(let event, .pastWorkout):
			"Event \(event.rawValue) is dated before today and is protected."
		case .ineligible(let event, .pastDate(let date)):
			"Event \(event.rawValue) cannot move to \(date.rawValue), which is before today."
		case .pastDate(let date):
			"Cannot add a workout dated \(date.rawValue), which is before today."
		case .targetUnreadable(let event):
			"Event \(event.rawValue) could not be read from intervals.icu, so nothing was prepared."
		case .keptUnreadable(let date):
			"The workouts on \(date.rawValue) could not be read from intervals.icu, so nothing was prepared."
		case .storageUnavailable:
			"The pending review could not be read on this phone, so nothing was prepared."
		}
	}
}

extension PendingReview {
	var json: JSONValue {
		switch self {
		case .none:
			.object(["kind": .string("none")])
		case .busy(let base):
			.object([
				"kind": .string("unavailable"),
				"reference": base.json,
				"details": .string(
					"The review is being written or has an unconfirmed change, so it cannot be revised now."
				),
			])
		case .waiting(let base, let remaining, let finished):
			.object([
				"kind": .string("pending"),
				"reference": base.json,
				"completedCount": .number(Double(finished)),
				"changes": .array(
					remaining.map { item in
						.object(["id": .string(item.id.ulid.rawValue), "change": item.action.json])
					}),
			])
		}
	}
}

extension ReviewBase {
	fileprivate var json: JSONValue {
		.object([
			"setId": .string(review.ulid.rawValue),
			"revision": .number(Double(revision.rawValue)),
		])
	}
}

extension ChangeAction {
	fileprivate var json: JSONValue {
		switch self {
		case .add(let add):
			var fields: [String: JSONValue] = [
				"kind": .string("add"),
				"sport": .string(add.payload.type == .ride ? "cycling" : "strength"),
				"date": .string(add.payload.date.rawValue),
				"name": .string(add.payload.name),
				"description": .string(add.payload.description),
			]
			fields["durationSeconds"] = add.payload.movingTime.map { .number(Double($0)) }
			fields["trainingLoad"] = add.payload.trainingLoad.map { .number(Double($0)) }
			return .object(fields)
		case .edit(let edit):
			return .object([
				"kind": .string("edit"),
				"eventId": .number(Double(edit.target.event.rawValue)),
				"patch": edit.patch.json,
				"reviewed": edit.target.json,
			])
		case .delete(let delete):
			return .object([
				"kind": .string("delete"),
				"eventId": .number(Double(delete.target.event.rawValue)),
				"reviewed": delete.target.json,
			])
		}
	}
}

extension WorkoutPatch {
	fileprivate var json: JSONValue {
		var fields: [String: JSONValue] = [:]
		fields["date"] = date.map { .string($0.rawValue) }
		fields["name"] = name.map(JSONValue.string)
		fields["durationSeconds"] = durationSeconds.map { .number(Double($0)) }
		fields["description"] = description.map(JSONValue.string)
		fields["trainingLoad"] = trainingLoad.map { .number(Double($0)) }
		fields["structure"] = workoutDocument
		return .object(fields)
	}
}

extension ReviewedTarget {
	fileprivate var json: JSONValue {
		switch self {
		case .reviewed(_, let snapshot):
			var fields: [String: JSONValue] = ["date": .string(snapshot.date.rawValue)]
			fields["name"] = snapshot.name.map(JSONValue.string)
			fields["durationSeconds"] = snapshot.durationSeconds.map { .number(Double($0)) }
			fields["description"] = snapshot.description.map(JSONValue.string)
			fields["load"] = snapshot.load.map { .number(Double($0)) }
			return .object(fields)
		case .upgradedWithoutSnapshot(_, let date):
			return .object(["date": .string(date.rawValue)])
		}
	}
}
