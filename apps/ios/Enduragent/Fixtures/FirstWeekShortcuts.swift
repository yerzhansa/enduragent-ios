#if DEBUG
	import EnduragentCoach
	import EnduragentCoachFixtures
	import Foundation

	extension FirstWeekFixture {
		static let shortcutFirstWordDelay: Duration = .seconds(8)
		static let shortcutLostDirective = "fixture:lost"
		static let shortcutLostOpening = "Ride 45 minutes at "

		static let workoutShortcutReply =
			"Ride 45 minutes at an easy endurance pace today. Keep the effort conversational and spin a high cadence. Nothing is on your calendar yet."

		static let planShortcutReply =
			"To build your training plan I need your current FTP, the hours you can ride each week, and the date of your event."

		static let statusShortcutReply =
			"On 1998-06-15 your Fitness is 42 with Fatigue at 49 and Form at -7. You are carrying some fatigue from the weekend."

		static func shortcutReply(to text: String, retry: Bool) -> ScriptedReply? {
			let typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
			let finished: String
			switch SlashRouting.parse(typed) {
			case .workout: finished = workoutShortcutReply
			case .plan: finished = planShortcutReply
			case .status: finished = statusShortcutReply
			case .start, .review, .language, nil: return nil
			}
			let trailing = typed.drop { !$0.isWhitespace }
				.trimmingCharacters(in: .whitespacesAndNewlines)
			if !retry, trailing == shortcutLostDirective {
				return ScriptedReply([
					.text(shortcutLostOpening), .fail(.connection(.networkConnectionLost)),
				])
			}
			return ScriptedReply(
				[.text(finished), .finish(reason: .stop)], requestDelay: shortcutFirstWordDelay)
		}
	}
#endif
