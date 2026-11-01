import Foundation

@testable import EnduragentCoach

struct SeedCalendarEntry: Sendable, Equatable {
	let key: String
	let title: String?
	let category: String
	let coachTagged: Bool
	let dayOffset: Int
	let minutes: Int?
	let load: Int?

	var externalID: String { LiveSeedCalendar.externalIDPrefix + key }
	var name: String { title.map { "\(LiveSeedPlan.namePrefix) \($0)" } ?? "" }
	var seconds: Int? { minutes.map { $0 * 60 } }

	func date(seededOn today: CivilDate) -> CivilDate {
		let date = today.adding(days: dayOffset)
		guard LiveCoachPlan.reviewTargetKeys.contains(key),
			LiveCoachPlan.weekday(date) == LiveCoachPlan.revisedWeekday
		else { return date }
		return date.adding(days: 1)
	}

	func requestBody(seededOn today: CivilDate) -> JSONValue {
		var fields: [String: JSONValue] = [
			"start_date_local": .string("\(date(seededOn: today).rawValue)T00:00:00"),
			"category": .string(category),
			"description": .string(LiveSeedCalendar.description),
			"external_id": .string(externalID),
			"name": .string(name),
			"tags": .array(coachTagged ? [.string(IntervalsPolicy.coachTag)] : []),
		]
		if category != "NOTE" {
			fields["type"] = .string(CalendarEventType.ride.rawValue)
		}
		if let seconds {
			fields["moving_time"] = .number(Double(seconds))
		}
		if let load {
			fields["icu_training_load"] = .number(Double(load))
		}
		return .object(fields)
	}
}

enum LiveSeedCalendar {
	static let externalIDPrefix = LiveSeedPlan.externalIDPrefix + "calendar-"
	static let description =
		"Synthetic calendar entry written by make live-seed for the Enduragent live checks."

	static let neverTargets = [
		SeedCalendarEntry(
			key: "athlete-workout", title: "Athlete's own endurance ride", category: "WORKOUT",
			coachTagged: false, dayOffset: 4, minutes: 50, load: 40),
		SeedCalendarEntry(
			key: "coach-race", title: "Coach-tagged club race", category: "RACE_A",
			coachTagged: true, dayOffset: 9, minutes: 90, load: 120),
		SeedCalendarEntry(
			key: "unnamed-note", title: nil, category: "NOTE", coachTagged: false, dayOffset: 3,
			minutes: nil, load: nil),
		SeedCalendarEntry(
			key: "past-workout", title: "Past endurance ride", category: "WORKOUT",
			coachTagged: true, dayOffset: -3, minutes: 60, load: 50),
	]

	static let targets = [
		SeedCalendarEntry(
			key: "T1", title: "T1 endurance ride", category: "WORKOUT", coachTagged: true,
			dayOffset: 2, minutes: 60, load: 50),
		SeedCalendarEntry(
			key: "T2", title: "T2 recovery ride", category: "WORKOUT", coachTagged: true,
			dayOffset: 3, minutes: 30, load: 15),
		SeedCalendarEntry(
			key: "K", title: "K kept workout", category: "WORKOUT", coachTagged: true,
			dayOffset: 2, minutes: 45, load: 35),
		SeedCalendarEntry(
			key: "T3", title: "T3 endurance ride", category: "WORKOUT", coachTagged: true,
			dayOffset: 5, minutes: 60, load: 55),
		SeedCalendarEntry(
			key: "T4", title: "T4 endurance ride", category: "WORKOUT", coachTagged: true,
			dayOffset: 6, minutes: 60, load: 50),
		SeedCalendarEntry(
			key: "T5", title: "T5 short ride", category: "WORKOUT", coachTagged: true,
			dayOffset: 8, minutes: 40, load: 30),
	]

	static let entries = neverTargets + targets

	static func window(around date: CivilDate) throws(ReadRangeRefusal) -> ReadRange {
		try ReadRange(oldest: date.adding(days: -183), newest: date.adding(days: 182), today: date)
	}
}
