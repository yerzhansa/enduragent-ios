import EnduragentCoach
import Foundation

public enum WorkoutReviewFixture {
	public static let editedEvent = EventID(rawValue: 301)
	public static let deletedEvent = EventID(rawValue: 302)
	public static let keptEvent = EventID(rawValue: 303)
	public static let renamed = "Threshold 3x10"

	public static func seed(_ intervals: FakeIntervalsClient, today: CivilDate) {
		let targets = [
			event(
				editedEvent, on: today.adding(days: 3), name: "Endurance", minutes: 60, load: 40,
				description: "Steady ride", coachCreated: true),
			event(
				deletedEvent, on: today.adding(days: 4), name: "Recovery spin", minutes: 30,
				load: 20, description: "Easy spin", coachCreated: true),
			event(
				keptEvent, on: today.adding(days: 2), name: "Commute", minutes: 45, load: 25,
				description: "Ride to work", coachCreated: false),
		]
		intervals.events.removeAll { event in targets.contains { $0.id == event.id } }
		intervals.events += targets
	}

	public static func mixed(today: CivilDate) -> String {
		preparation([
			#"{"kind":"add-cycling","date":"\#(today.adding(days: 1).rawValue)","workout":\#(ride),"trainingLoad":42}"#,
			#"{"kind":"add-strength","date":"\#(today.adding(days: 2).rawValue)","name":"Core strength","durationMinutes":30,"effort":"Moderate","description":"3 rounds: plank 45s, side plank 30s, glute bridge 12","trainingLoad":18}"#,
			#"{"kind":"edit","eventId":\#(editedEvent.rawValue),"patch":{"structure":\#(threshold)}}"#,
			#"{"kind":"delete","eventId":\#(deletedEvent.rawValue)}"#,
		])
	}

	public static var deleteOnly: String {
		preparation([#"{"kind":"delete","eventId":\#(deletedEvent.rawValue)}"#])
	}

	public static func rename(after toolResults: [String]) throws -> String? {
		let fields =
			try toolResults.reversed().map(JSONValue.parse)
			.compactMap { $0.objectFields["data"]?.objectFields }
			.first { $0["kind"] == .string("pending") } ?? [:]
		guard case .object(let reference)? = fields["reference"],
			let edit = fields["changes"]?.arrayValue?.first(where: {
				$0.objectFields["change"]?.objectFields["kind"]?.stringValue == "edit"
			}), let id = edit.objectFields["id"]?.stringValue,
			let setId = reference["setId"]?.stringValue,
			let revision = reference["revision"]?.numberValue
		else { return nil }
		return
			#"{"preparation":{"kind":"revise","base":{"setId":"\#(setId)","revision":\#(Int(revision))},"replacements":[{"id":"\#(id)","change":{"kind":"edit","eventId":\#(editedEvent.rawValue),"patch":{"name":"\#(renamed)"}}}]}}"#
	}

	public static let ride =
		#"{"name":"Endurance 50","steps":[{"type":"warmup","duration":{"value":10,"unit":"minutes"},"power":{"kind":"percent_ftp","value":55}},{"type":"steady","duration":{"value":30,"unit":"minutes"},"power":{"kind":"percent_ftp","low":65,"high":75}},{"type":"cooldown","duration":{"value":10,"unit":"minutes"},"power":{"kind":"percent_ftp","value":50}}]}"#

	public static let threshold =
		#"{"steps":[{"type":"warmup","duration":{"value":15,"unit":"minutes"},"power":{"kind":"percent_ftp","value":55}},{"type":"set","repeat":3,"interval":{"type":"interval","duration":{"value":10,"unit":"minutes"},"power":{"kind":"percent_ftp","value":95}},"recovery":{"type":"recovery","duration":{"value":5,"unit":"minutes"},"power":{"kind":"percent_ftp","value":50}}},{"type":"cooldown","duration":{"value":15,"unit":"minutes"},"power":{"kind":"percent_ftp","value":50}}]}"#

	private static func preparation(_ changes: [String]) -> String {
		#"{"preparation":{"kind":"complete","changes":[\#(changes.joined(separator: ","))]}}"#
	}

	private static func event(
		_ id: EventID, on date: CivilDate, name: String, minutes: Int, load: Int,
		description: String, coachCreated: Bool
	) -> CalendarEvent {
		CalendarEvent(
			description: description, type: CalendarEventType.ride.rawValue, id: id,
			startDateLocal: "\(date.rawValue)T00:00:00", name: name, category: "WORKOUT",
			externalId: nil, uid: nil, tags: coachCreated ? [IntervalsPolicy.coachTag] : [],
			coachCreated: coachCreated, movingTime: minutes * 60, trainingLoad: load)
	}
}
