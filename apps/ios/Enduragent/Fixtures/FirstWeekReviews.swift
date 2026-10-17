#if DEBUG
	import EnduragentCoach
	import EnduragentCoachFixtures

	extension FirstWeekFixture {
		static let reviewMixedDirective = "fixture:review-mixed"
		static let reviewDeleteDirective = "fixture:review-delete"
		static let reviewRenameDirective = "fixture:review-rename"
		static let reviewPreparedReply = "I've prepared the changes. Check each card first."
		static let reviewRenamedReply = "I renamed the edited workout. Check the cards again."

		static func reviewReply(
			_ request: ScriptedRequest, intervals: FakeIntervalsClient
		) -> ScriptedReply? {
			let text = request.text.trimmingCharacters(in: .whitespacesAndNewlines)
			guard
				[reviewMixedDirective, reviewDeleteDirective, reviewRenameDirective].contains(text)
			else { return nil }
			guard request.offersTrainingTools else {
				return ScriptedReply([.text(trainingDataMissing), .finish(reason: .stop)])
			}
			switch text {
			case reviewMixedDirective:
				return prepared(WorkoutReviewFixture.mixed(today: today), request, intervals)
			case reviewDeleteDirective:
				return prepared(WorkoutReviewFixture.deleteOnly, request, intervals)
			default:
				return renamed(request)
			}
		}

		private static func prepared(
			_ arguments: String, _ request: ScriptedRequest, _ intervals: FakeIntervalsClient
		) -> ScriptedReply {
			if request.step == 0 {
				WorkoutReviewFixture.seed(intervals, today: today)
			}
			return ScriptedReply([
				.toolCall(name: ToolName.prepareWorkoutChanges.rawValue, arguments: arguments),
				.finish(reason: .toolCalls), .text(reviewPreparedReply), .finish(reason: .stop),
			]).step(request.step)
		}

		private static func renamed(_ request: ScriptedRequest) -> ScriptedReply {
			switch request.step {
			case 0:
				return ScriptedReply([
					.toolCall(name: ToolName.getPendingWorkoutChanges.rawValue, arguments: "{}"),
					.finish(reason: .toolCalls),
				])
			case 1:
				do {
					guard
						let arguments = try WorkoutReviewFixture.rename(after: request.toolResults)
					else {
						return ScriptedReply([
							.text("Review fixture found no pending edit to rename."),
							.finish(reason: .stop),
						])
					}
					return ScriptedReply([
						.toolCall(
							name: ToolName.prepareWorkoutChanges.rawValue, arguments: arguments),
						.finish(reason: .toolCalls),
					])
				} catch {
					return ScriptedReply([
						.text("Review fixture could not decode its tool results: \(error)"),
						.finish(reason: .stop),
					])
				}
			default:
				return ScriptedReply([.text(reviewRenamedReply), .finish(reason: .stop)])
			}
		}
	}
#endif
