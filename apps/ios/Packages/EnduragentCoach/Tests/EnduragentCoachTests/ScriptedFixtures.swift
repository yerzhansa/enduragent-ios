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

let workoutPreparation: [ScriptedEvent] = [
	.toolCall(
		name: "prepare_workout_changes",
		arguments:
			#"{"preparation":{"kind":"complete","changes":[\#(PreparationFixture.ride(on: "1998-06-14"))]}}"#
	),
	.finish(reason: .toolCalls),
]
