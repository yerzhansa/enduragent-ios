#if DEBUG
	import EnduragentCoach
	import EnduragentCoachFixtures

	extension FirstWeekFixture {
		static let trainingDataDirective = "fixture:training-data"
		static let trainingDataMissing =
			"intervals.icu is not connected, so I can't read your training profile or calendar. I can discuss general training. Connect in Settings to use your data."

		static func install(_ display: FixtureTrainingDisplay?, on intervals: FakeIntervalsClient) {
			guard let display else { return }
			let rejected = IntervalsError(code: "http", details: "Fixture rejection", status: 401)
			let unavailable = IntervalsError(code: "http", details: "Fixture outage", status: 503)
			switch display {
			case .profileRejected:
				intervals.setProfileOutcome(.failure(rejected), once: true)
			case .profileRequestRejected:
				intervals.setProfileOutcome(
					.failure(
						IntervalsError(
							code: "http", details: "Fixture missing account", status: 404)),
					once: true)
			case .profileUnavailable:
				intervals.setProfileOutcome(.failure(unavailable), once: true)
			case .wellnessRejected:
				intervals.setWellnessOutcome(.failure(rejected), once: true)
			case .wellnessUnavailable:
				intervals.setWellnessOutcome(.failure(unavailable), once: true)
			case .emptyWellness:
				intervals.wellness = []
			case .partialWellness:
				intervals.wellness = [
					WellnessDay(date: today, fitness: 42, fatigue: nil, form: nil)
				]
			}
		}

		static func trainingDataReply(_ request: ScriptedRequest) -> ScriptedReply {
			if request.step == 0 {
				return ScriptedReply([
					.toolCall(name: ToolName.intervalsFetchAthlete.rawValue, arguments: "{}"),
					.toolCall(
						name: ToolName.intervalsListEvents.rawValue, arguments: #"{"days":7}"#),
					.finish(reason: .toolCalls),
				])
			}
			do {
				let results = try request.toolResults.map(JSONValue.parse)
				for result in results {
					guard case .object(let envelope) = result,
						case .object(let data)? = envelope["data"]
					else { continue }
					if data["error"] == .string("not_connected") {
						return ScriptedReply([.text(trainingDataMissing), .finish(reason: .stop)])
					}
					if case .string(let name)? = data["name"],
						results.contains(where: {
							guard case .object(let envelope) = $0,
								case .array? = envelope["data"]
							else { return false }
							return true
						})
					{
						return ScriptedReply([
							.text("I can read \(name)'s training profile and calendar."),
							.finish(reason: .stop),
						])
					}
				}
				return ScriptedReply([
					.text("Training-data fixture did not receive a profile and calendar."),
					.finish(reason: .stop),
				])
			} catch {
				return ScriptedReply([
					.text("Training-data fixture could not decode its tool results: \(error)"),
					.finish(reason: .stop),
				])
			}
		}
	}
#endif
