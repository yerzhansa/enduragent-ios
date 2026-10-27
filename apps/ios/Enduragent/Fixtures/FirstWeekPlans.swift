#if DEBUG
	import EnduragentCoach
	import EnduragentCoachFixtures

	extension FirstWeekFixture {
		static let planSaveDirective = "fixture:plan-save"
		static let planSaveLongDirective = "fixture:plan-save-long"
		static let planSaveSparseDirective = "fixture:plan-save-sparse"
		static let planSaveNotPreparedDirective = "fixture:plan-save-not-prepared"
		static let planSaveWeeks = 12
		static let planSaveGoal = "Finish the June gran fondo"
		static let planSaveReply = "Your plan is ready. Tap Save plan on the card to keep it."
		static let planSaveNotPreparedReply = "I tried to save two plans at once."
		static let planSaveSparseName = "Spring Base Plan"
		static let planSaveLongName =
			"Dolomites Gran Fondo Endurance and Climbing Preparation Plan for the Long June Weekend"
		static let planSaveLongGoal =
			"Ride the full 170 km route with 4,000 m of climbing and finish strong on the last pass"

		static func planSaveDirective(weeks: Int) -> String {
			"\(planSaveDirective) \(weeks)"
		}

		static func planName(weeks: Int) -> String {
			"\(weeks)-Week Gran Fondo Plan"
		}

		static func planSaveReply(_ request: ScriptedRequest) -> ScriptedReply? {
			let words = request.text.trimmingCharacters(in: .whitespacesAndNewlines)
				.split(separator: " ").map(String.init)
			guard let directive = words.first else { return nil }
			let arguments = words.dropFirst()
			switch directive {
			case planSaveDirective where arguments.isEmpty:
				return prepared([weeksPlan(planSaveWeeks)], request)
			case planSaveDirective:
				guard arguments.count == 1, let weeks = arguments.first.flatMap({ Int($0) }),
					weeks > 2
				else { return nil }
				return prepared([weeksPlan(weeks)], request)
			case planSaveLongDirective where arguments.isEmpty:
				return prepared([longPlan], request)
			case planSaveSparseDirective where arguments.isEmpty:
				return prepared([sparsePlan], request)
			case planSaveNotPreparedDirective where arguments.isEmpty:
				return prepared(
					[weeksPlan(planSaveWeeks), weeksPlan(planSaveWeeks)], request,
					reply: planSaveNotPreparedReply)
			default:
				return nil
			}
		}

		private static func prepared(
			_ plans: [String], _ request: ScriptedRequest, reply: String = planSaveReply
		) -> ScriptedReply {
			ScriptedReply(
				plans.map {
					.toolCall(name: ToolName.planSave.rawValue, arguments: #"{"plan":\#($0)}"#)
				} + [.finish(reason: .toolCalls), .text(reply), .finish(reason: .stop)]
			).step(request.step)
		}

		private static func weeksPlan(_ weeks: Int) -> String {
			let build = (weeks - 2) / 2
			let phases = [
				phase(1, "Base", focus: "base_building", weeks: weeks - 2 - build, hours: "7"),
				phase(2, "Build", focus: "threshold", weeks: build, hours: "8.5"),
				phase(3, "Taper", focus: "taper", weeks: 2, hours: "4.5"),
			]
			return
				#"{"name":"\#(planName(weeks: weeks))","primaryGoal":"\#(planSaveGoal)","totalWeeks":\#(weeks),"cycleLength":7,"status":"draft","phases":[\#(phases.joined(separator: ","))]}"#
		}

		private static let longPlan =
			#"{"name":"\#(planSaveLongName)","primaryGoal":"\#(planSaveLongGoal)","totalWeeks":16,"cycleLength":7,"status":"draft","phases":[\#([phase(1, "Aerobic", focus: "aerobic_development", weeks: 5, hours: "9.5"), phase(2, "Threshold", focus: "threshold", weeks: 5, hours: "11"), phase(3, "Race preparation", focus: "race_prep", weeks: 4, hours: "12.5"), phase(4, "Taper", focus: "taper", weeks: 2, hours: "6")].joined(separator: ","))]}"#

		private static let sparsePlan =
			#"{"name":"\#(planSaveSparseName)","phases":[{"focus":"general_fitness"},{"durationWeeks":3},{"volumeTargets":{"cycling":{"sessionsPerCycle":3,"hoursPerCycle":5.5}}}]}"#

		private static func phase(
			_ number: Int, _ name: String, focus: String, weeks: Int, hours: String
		) -> String {
			#"{"number":\#(number),"name":"\#(name)","durationWeeks":\#(weeks),"durationCycles":\#(weeks),"focus":"\#(focus)","volumeTargets":{"cycling":{"sessionsPerCycle":4,"hoursPerCycle":\#(hours)}},"keyAdditions":[]}"#
		}
	}
#endif
