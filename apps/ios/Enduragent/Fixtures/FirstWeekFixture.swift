import EnduragentCoach
import Foundation

enum FirstWeekFixture {
	static let athleteName = "Ada Kovač"
	static let today: CivilDate = "1998-06-15"
	static let tomorrow: CivilDate = "1998-06-16"

	static let workoutArguments = """
	{"date":"1998-06-16","workout":{"name":"Endurance with tempo","steps":[{"type":"warmup","duration":{"value":10,"unit":"minutes"},"power":{"kind":"percent_ftp","low":55,"high":65}},{"type":"set","repeat":2,"interval":{"type":"interval","duration":{"value":10,"unit":"minutes"},"power":{"kind":"percent_ftp","low":76,"high":90}},"recovery":{"type":"recovery","duration":{"value":5,"unit":"minutes"},"power":{"kind":"percent_ftp","low":55,"high":65}}},{"type":"cooldown","duration":{"value":10,"unit":"minutes"},"power":{"kind":"percent_ftp","low":55,"high":65}}]}}
	"""

	static func install(on intervals: FakeIntervalsClient) {
		intervals.athleteName = athleteName
		intervals.ftp = 250
		intervals.wellness = [
			WellnessDay(date: today, fitness: 42, fatigue: 49, form: -7),
		]
		intervals.activities = [
			.ride(name: "Tuesday sweet spot", date: "1998-06-09", durationS: 3_600, trainingLoad: 72),
			.ride(name: "Saturday group ride", date: "1998-06-13", durationS: 7_800, trainingLoad: 118),
		]
	}

	static func install(on credits: FakeCreditsClient) {
		credits.grantResult = .success(.minted(.of(200)))
		credits.catalogResult = .success(
			.catalog(
				purchasesEnabled: false,
				scale: .perUsd(100),
				packs: [
					.pack(id: "icu.enduragent.credits.small", credits: .of(500)),
					.pack(id: "icu.enduragent.credits.large", credits: .of(2000)),
				]
			)
		)
		credits.balanceResult = .success(.balance(.of(200)))
	}

	static func script(for text: String) -> [ScriptedEvent] {
		let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
		if SlashRouting.parse(trimmed) == .review {
			return [
				.text("Saturday group ride on 1998-06-13, 2 h 10 min, Training Load 118. It sat a little above your Fatigue of 49 against Fitness 42. Keep the next ride easier."),
				.finish(reason: .stop),
			]
		}
		if trimmed.lowercased().hasPrefix("remember that") {
			return [
				.text("Noted. I'll remember you ride with a group on Saturdays."),
				.finish(reason: .stop),
			]
		}
		if isWorkoutRequest(trimmed) {
			return [
				.toolCall(name: ToolName.intervalsCreateWorkout.rawValue, arguments: workoutArguments),
				.finish(reason: .toolCalls),
				.text("I've prepared the ride. Confirm to add it."),
				.finish(reason: .stop),
			]
		}
		return [
			.text("This week has Tuesday sweet spot, 1 h, Training Load 72, and Saturday group ride, 2 h 10 min, Training Load 118. Two solid rides with a quieter stretch between them."),
			.finish(reason: .stop),
		]
	}

	private static func isWorkoutRequest(_ text: String) -> Bool {
		let lowered = text.lowercased()
		return lowered.contains("endurance ride") || lowered.contains("60 minute endurance")
	}
}
