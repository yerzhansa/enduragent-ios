#if DEBUG
	import EnduragentCoach
	import EnduragentCoachFixtures
	import Foundation

	extension FirstWeekFixture {
		static let toolProgressDirective = "fixture:slow-tool"
		static let slowToolModelDelay: Duration = .seconds(8)
		static let slowToolReadDelay: Duration = .seconds(20)
		static let toolProgressIntroduction = "Checking your recent rides. "
		static let toolProgressCompletion = "I've prepared the ride. Confirm to add it."

		static func toolProgressReply(_ request: ScriptedRequest) -> ScriptedReply {
			guard request.tools.contains(.intervalsCreateWorkout) else {
				return ScriptedReply([.text(trainingDataMissing), .finish(reason: .stop)])
			}
			return ScriptedReply(
				[
					.text(toolProgressIntroduction),
					.toolCall(
						name: ToolName.intervalsFetchActivities.rawValue, arguments: #"{"days":7}"#),
					.finish(reason: .toolCalls),
					.toolCall(
						name: ToolName.intervalsCreateWorkout.rawValue, arguments: workoutArguments),
					.finish(reason: .toolCalls),
					.text(toolProgressCompletion),
					.finish(reason: .stop),
				], requestDelay: request.step == 0 ? slowToolModelDelay : nil
			).step(request.step)
		}
	}
#endif
