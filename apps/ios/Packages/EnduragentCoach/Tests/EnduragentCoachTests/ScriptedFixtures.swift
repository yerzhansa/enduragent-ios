import EnduragentCoachFixtures

@testable import EnduragentCoach

extension ScriptedEvent {
	static let saturdayScheduleWrite: ScriptedEvent = .toolCall(
		name: "memory_write",
		arguments: #"{"type":"memory","section":"schedule","content":"Group ride on Saturdays."}"#)

	static let untypedSaturdayScheduleWrite: ScriptedEvent = .toolCall(
		name: "memory_write",
		arguments: #"{"section":"schedule","content":"Group ride on Saturdays."}"#)
}

let workoutProposal: [ScriptedEvent] = [
	.toolCall(
		name: "intervals_create_workout",
		arguments:
			#"{"date":"1998-06-14","workout":{"name":"Endurance","steps":[{"type":"steady","duration":{"value":60,"unit":"minutes"},"power":{"kind":"percent_ftp","low":56,"high":75}}]}}"#
	),
	.finish(reason: .toolCalls),
]
