import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

@Suite struct ActivityReviewRulesTests {
	static let ride = Activity.recorded(
		"i1234569", "Lunch ride", on: "1998-06-10", at: 12 * 3_600 + 15 * 60, [.duration: 3_000])
	static let hidden = Activity.recorded(
		"i1234570", "Evening ride", on: "1998-06-10", at: 18 * 3_600, [.duration: 2_700])

	let transport = FakeModelTransport()
	let store = InMemoryRecordLog()
	let intervals = FakeIntervalsClient(athleteName: "Ada", ftp: 250)
	let clock = FixedClock(now: "1998-06-13T08:00:00+02:00", timeZone: "Europe/Amsterdam")

	@Test func legsAreInferredFromStartsWithinThirtyMinutesAndNeverFromAGroupingField()
		async throws
	{
		let carried = try await carried()

		#expect(
			carried.rules.says(
				"4. Otherwise: intervals.icu supplies no grouping field, so use start-time proximity within 30 minutes to treat activities as possible legs of one workout, order the legs by start time, and state that the grouping is an inference. When a start has a date and no time of day, make no grouping at all."
			))
		#expect(carried.rules.says("Nothing in the data marks two activities as one workout."))
		#expect(
			carried.topic.says(
				"intervals.icu does not mark which activities belong to one workout, so legs are inferred from starts within 30 minutes of each other. Summarize every leg in start-time order and say the grouping is inferred."
			))
		for text in [carried.rules, carried.topic] {
			#expect(!text.says("grouping fields"))
			#expect(!text.says("recorded-workout grouping"))
		}
	}

	@Test func everyLegIsSummarizedAndOneLegNeverJudgesTheWholeWorkout() async throws {
		let carried = try await carried()

		#expect(
			carried.rules.says(
				"Summarize every activity in the inferred group in start-time order. At Tier B+, detail may stay scoped to the requested sport's main non-transition activity, or one representative non-transition activity when no sport was requested. State which legs were not detailed, and never judge the whole workout or change the next session from one selected leg alone."
			))
		#expect(
			carried.topic.says(
				"If detail is requested for only one leg, say which legs were not detailed and do not use that leg alone to judge the whole workout or change the next session."
			))
	}

	@Test func evidenceStatementNamesWhatTheListAndTheDetailHoldAndWhatTheyDoNot() async throws {
		let carried = try await carried()

		#expect(
			carried.topic.says(
				"The activity list gives each activity an `id`, a title, a sport, a local start, a duration, and a distance and, when recorded, Load, Intensity, average and weighted average power, average and maximum heart rate, elevation gain, and FTP."
			))
		#expect(
			carried.topic.says(
				"Activity detail adds, when recorded, the athlete's notes, indoor or not, RPE, feel, average cadence, average and maximum speed, calories, work, variability index, efficiency factor, decoupling, and the time in each power zone and each heart-rate zone. It also adds `laps` when intervals.icu supplies them: each lap has its number, a label or kind, and the same measurements as a listed activity."
			))
		#expect(
			carried.topic.says(
				"These reads hold no planned targets, no plan compliance, and no wellness. A measurement that is absent is unavailable. Do not infer it from another measurement."
			))
		#expect(
			carried.rules.says(
				"Each listed activity has an `id`, a local start, and the measurements intervals.icu recorded for it; the cycling review skill lists them."
			))
		#expect(
			carried.rules.says(
				"Use only fields that are actually present: an absent measurement is unavailable, never inferred from another."
			))
		#expect(!carried.topic.says("do not contain"))
	}

	@Test func briefReviewUsesTheListOnlyAndMayStateItsRecordedMeasurements() async throws {
		let brief = try await carried().tier("A", until: "- **Tier B")

		#expect(
			brief.says(
				"explicit `brief` / `summary`. Call only `intervals_fetch_activities` and use only available summary fields. You may state the measurements the list supplies as recorded values, Load and Intensity among them. One-line factual takeaway; no per-lap claims."
			))
		#expect(!brief.says("intervals_fetch_activity`"))
		#expect(!brief.says("intervals_fetch_streams"))
		#expect(!brief.says("no intensity"))
	}

	@Test func defaultReviewReadsTheChosenActivityByItsListedIdAndMayStateLapMeasurements()
		async throws
	{
		let carried = try await carried()
		let standard = try carried.tier("B", until: "- **Tier C")

		#expect(
			standard.says(
				"default review. Call `intervals_fetch_activity` with the selected activity's `id` exactly as the list gave it, and use its `laps` when supplied. You may state the measurements a lap carries as recorded values; do not rename laps as prescribed reps or invent targets."
			))
		#expect(!standard.says("timing and distance observations only"))
		#expect(carried.rules.says("- No depth flag → Tier B."))
	}

	@Test func onlyADeepReviewReadsTheStreamSummary() async throws {
		let carried = try await carried()

		#expect(
			try carried.tier("C", until: "Manual overrides:").says(
				"explicit `deep` / `in depth` only. Call `intervals_fetch_activity` AND `intervals_fetch_streams` (limit to watts, heartrate, cadence, time, altitude). Follow the stream-evidence limits in the `intervals_fetch_streams` tool description."
			))
		#expect(try !carried.tier("B", until: "- **Tier C").says("intervals_fetch_streams"))
		#expect(carried.rules.components(separatedBy: "intervals_fetch_streams").count == 3)
		#expect(
			try carried.description(of: .intervalsFetchStreams).says(
				"call it only for Tier C deep reviews the athlete explicitly requests. For Tier A/B use `intervals_fetch_activities` and `intervals_fetch_activity`."
			))
	}

	@Test func measurementsAloneNeverEstablishQualityRecoveryReadinessOrPlanCompliance()
		async throws
	{
		let carried = try await carried()

		#expect(
			carried.rules.says(
				"**Evidence-limit rule:** summary measurements, lap measurements, and independently summarized stream statistics alone cannot establish session quality, recovery, readiness, or justify changing the next session. In that case, answer question 1 with the factual record and say there is not enough evidence to judge how it went; ask for the session goal plus RPE or reported feel. For question 2, name only a factual observation or the missing evidence. For question 3, do not alter the next session: keep the existing plan pending the athlete's feel or available wellness/context. Never say \"nothing — this was clean\" from those fields alone."
			))
		#expect(
			carried.rules.says(
				"Activity data does not by itself link to a planned calendar prescription; never infer plan compliance from it."
			))
		#expect(
			carried.rules.says(
				"Skip plan-compliance analysis unless the athlete supplies the plan separately."))
		#expect(
			carried.rules.says(
				"Never fabricate intensity, load, plan-compliance, or interval metrics."))
		#expect(carried.rules.says("do NOT invent pacing curves or best-efforts content."))
		#expect(
			try carried.description(of: .intervalsFetchStreams).says(
				"do not use it for pacing, duration-based best efforts, quartile trends, decoupling, HR recovery, fade patterns, or indoor/outdoor comparisons. Use only minimum, maximum, and mean as descriptive recorded observations. They alone cannot establish session quality, recovery, or readiness, or justify changing the next session."
			))
	}

	@Test func startIsShownAsTheAthletesLocalTimeAndTheTimeIsLeftOutOfADateOnlyStart()
		async throws
	{
		let carried = try await carried()

		#expect(
			carried.rules.says(
				"A start is the athlete's local time as intervals.icu recorded it: show it as local time, never label it as universal time or any other time zone, and leave the time out when the start has a date only."
			))
		#expect(
			carried.topicTables().first?.dropFirst().first
				== ["Date / start", "local date and local time; date alone when no time"])
		for text in [carried.rules, carried.topic] {
			#expect(!text.says("offset"))
			#expect(!text.says("UTC"))
		}
	}

	@Test func numbersTablesNameOnlyTheRowsAndLapColumnsThePhoneSupplies() async throws {
		let carried = try await carried()
		let tables = carried.topicTables()
		try #require(tables.count == 4)

		#expect(
			tables[0].map(\.[0]) == [
				"Metric", "Date / start", "Sport", "Duration", "Distance", "Load", "Intensity",
				"Average / weighted average power", "Average / max HR", "Elevation gain", "FTP",
			])
		#expect(tables[0][2] == ["Sport", "sport"])
		#expect(tables[0][3] == ["Duration", "hh:mm:ss"])
		#expect(
			tables[1].map(\.[0]) == [
				"Metric", "Indoor", "RPE / feel", "Average cadence", "Average / max speed",
				"Calories", "Work", "Variability index / efficiency factor", "Decoupling",
				"Time in power / heart-rate zones",
			])
		#expect(carried.topic.says("After an activity detail read, append only the rows it supplied:"))
		#expect(tables[3] == [["Lap", "Label / kind", "Duration", "Distance"]])
		#expect(
			carried.topic.says(
				"Add an average power column and an average HR column when any lap has that measurement."
			))
		#expect(carried.topic.says("Render a missing value as unavailable rather than zero."))
		#expect(carried.rules.says("Render nullable lap cells as unavailable."))
		for absent in ["sub-sport", "Elapsed", "Timer", "timer", "sequence", "Start ("] {
			#expect(!carried.topic.says(absent), "the review topic names \(absent)")
		}
	}

	@Test func failureRulesNameExactlyTheAnswersAFailedDetailReadGives() async throws {
		let carried = try await carried()
		intervals.activities = [Self.ride, Self.hidden]
		intervals.details[Self.hidden.id] = .hiddenByStrava
		var returned = [try await detail(of: "i7654321"), try await detail(of: Self.hidden.id.rawValue)]
		#expect(try await detail(of: Self.ride.id.rawValue)["lapsSupplied"] == .bool(false))
		intervals.fail(.activity, with: IntervalsError(code: "http", details: "status 503"))
		returned.append(try await detail(of: Self.ride.id.rawValue))

		let named = carried.rules.matches(of: try Regex("`(activity_[a-z_]+)`")).compactMap {
			$0.output[1].substring.map(String.init)
		}
		#expect(named.sorted() == returned.compactMap { $0["error"]?.stringValue }.sorted())
		#expect(returned.allSatisfy { $0["details"]?.stringValue?.isEmpty == false })
		#expect(
			carried.rules.says(
				"- When an activity read returns an `error`, name the limit in plain words and do not present a full review or invent one: `activity_not_found` → I can't find that activity; `activity_hidden_by_strava` → Strava hides that activity from me, then give the guidance in its `details`; `activity_detail_unavailable` → I couldn't read that activity's detail, with the cause its `details` names; any other `error` → I couldn't read it, then relay its `details`. Never surface the raw error code."
			))
		#expect(
			carried.rules.says(
				"- Activity detail returns `lapsSupplied: false`: intervals.icu supplied no laps. Say lap data is unavailable for this activity, make no per-lap claim, and do not present the result as a full review."
			))
		for unreachable in ["`Network`", "`Timeout`", "`message`"] {
			#expect(!carried.rules.says(unreachable), "the rules name \(unreachable)")
		}
	}

	@Test func coachStillAsksBeforeLookingFurtherBackReviewingAnOldSessionOrChoosingAMatch()
		async throws
	{
		let rules = try await carried().rules

		#expect(rules.says("1. Call `intervals_fetch_activities` for the last 7 days, newest first."))
		#expect(
			rules.says(
				"2. If empty: reply \"No activity in the last 7 days — want me to look further back?\" and stop."
			))
		#expect(
			rules.says(
				"3. If newest activity is older than 7 days: reply \"Your last session was X days ago — want me to review that?\" and stop until the athlete confirms."
			))
		#expect(
			rules.says(
				"- If the bounded summary cannot resolve the hint, or multiple recent activities match, ask the athlete to clarify before proceeding."
			))
	}

	@Test func toolDescriptionsSayHowTheIdTravelsAndStateNoLimitThePhoneDoesNotEnforce()
		async throws
	{
		let carried = try await carried()
		let list = try carried.description(of: .intervalsFetchActivities)
		let detail = try carried.description(of: .intervalsFetchActivity)
		let streams = try carried.description(of: .intervalsFetchStreams)

		#expect(
			list.says(
				"Each activity has an `id`, a local `start`, and the measurements intervals.icu recorded for it. Pass an `id` exactly as listed to `intervals_fetch_activity` or `intervals_fetch_streams`."
			))
		#expect(
			detail.says(
				"Fetch one recorded activity by the `id` that `intervals_fetch_activities` listed, passed exactly as listed."
			))
		#expect(
			streams.says(
				"Fetch time-series channels for an activity by the `id` that `intervals_fetch_activities` listed, passed exactly as listed."
			))
		#expect(
			streams.says(
				"Returns only per-channel min/max/mean over the full series plus the sample count; no per-second data;"
			))
		for tool in [ToolName.intervalsFetchActivity, .intervalsFetchStreams] {
			#expect(
				try carried.identifierDescription(of: tool)
					== "Activity `id` from intervals_fetch_activities. Pass exactly as listed.")
		}
		for limit in ["200", "16", "up to", "narrow the date range", "64-hex", "legacy"] {
			for text in [list, detail, streams] {
				#expect(!text.says(limit), "an activity tool description states \(limit)")
			}
		}
	}

	@Test(arguments: [
		"workoutId", "sessionSequence", "subSport", "UTC", "NotFound", "Unauthorized", "RateLimit",
	])
	func reviewTextsNameNothingOnlyNpmsActivityStoreHas(word: String) async throws {
		for (name, text) in try await carried().reviewTexts() {
			#expect(!text.contains(word), "\(name) names \(word)")
		}
	}

	@Test(arguments: ["store-backed", "canonical"])
	func reviewTextsDoNotDescribeNpmsActivityStoreInAnyCase(word: String) async throws {
		for (name, text) in try await carried().reviewTexts() {
			#expect(!text.lowercased().contains(word), "\(name) names \(word)")
		}
	}

	@Test(arguments: [
		"reviewRules", "intervals_fetch_activities", "intervals_fetch_activity",
		"intervals_fetch_streams", "activityId",
	])
	func carriedTextIsNpmsOnceItsRecordedDifferencesAreApplied(name: String) async throws {
		let record = try #require(
			try JSONDecoder().decode(NpmReviewTexts.self, from: try fixtureData("review-texts-npm"))
				.texts[name])
		try #require(!record.differences.isEmpty)
		var expected = record.npm
		for difference in record.differences {
			let parts = expected.components(separatedBy: difference.npm)
			try #require(
				parts.count == 2,
				"the recorded npm passage occurs \(parts.count - 1) times in \(name)")
			expected = parts.joined(separator: difference.phone)
		}

		#expect(try await carried().text(named: name) == expected)
	}

	private func carried() async throws -> CarriedReviewTexts {
		transport.respond = ScriptedReply.sequence(
			[.text("Which ride?"), .finish(reason: .stop)], otherwise: transport.respond)
		let coach = await makeCoach(transport: transport, store: store)

		_ = try await coach.sendAndSettle("/review")

		let request = try #require(transport.requests.first)
		let system = try #require(request.messages.first)
		try #require(system.role == .system)
		return try CarriedReviewTexts(system: system.content, tools: request.tools)
	}

	private func detail(of id: String) async throws -> [String: JSONValue] {
		let outcome = try await makeToolRuntime(
			intervals: intervals,
			ledger: Ledger(
				log: InMemoryRecordLog(), clock: clock, diagnostics: DiagnosticsLog(clock: clock)),
			clock: clock
		).execute(
			name: .intervalsFetchActivity, arguments: .object(["activityId": .string(id)]),
			scope: TurnScope(stamp: testStamp(), policy: .npm, ladder: .npm, uptime: .zero)
		).outcome
		guard case .result(let json) = outcome else {
			throw IntervalsError(code: "no_result", details: "\(outcome)")
		}
		return try #require(json.objectFields["data"]).objectFields
	}
}
