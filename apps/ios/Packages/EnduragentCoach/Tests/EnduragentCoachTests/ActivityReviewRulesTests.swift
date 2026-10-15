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

		for text in [carried.rules, carried.topic] {
			#expect(text.says("within 30 minutes"))
			#expect(!text.says("grouping fields"))
			#expect(!text.says("recorded-workout grouping"))
		}
		#expect(carried.rules.says("state that the grouping is an inference"))
		#expect(carried.topic.says("say the grouping is inferred"))
		#expect(carried.rules.says("no grouping field"))
		#expect(carried.rules.says("date and no time of day, make no grouping at all"))
	}

	@Test func everyLegIsSummarizedAndOneLegNeverJudgesTheWholeWorkout() async throws {
		let carried = try await carried()

		#expect(carried.rules.says("Summarize every activity in the inferred group"))
		for text in [carried.rules, carried.topic] {
			#expect(text.says("which legs were not detailed"))
		}
		#expect(carried.rules.says("never judge the whole workout"))
	}

	@Test func evidenceStatementNamesWhatTheListAndTheDetailHoldAndWhatTheyDoNot() async throws {
		let carried = try await carried()

		for measurement in ["`id`", "Load", "Intensity", "FTP", "`laps`", "decoupling", "RPE"] {
			#expect(carried.topic.says(measurement), "the review topic leaves out \(measurement)")
		}
		#expect(carried.topic.says("no planned targets, no plan compliance, and no wellness"))
		#expect(carried.rules.says("never inferred from another"))
		#expect(!carried.topic.says("do not contain"))
	}

	@Test func briefReviewUsesTheListOnlyAndMayStateItsRecordedMeasurements() async throws {
		let brief = try await carried().tier("A", until: "- **Tier B")

		#expect(brief.says("Call only `intervals_fetch_activities`"))
		#expect(brief.says("Load and Intensity"))
		#expect(!brief.says("intervals_fetch_activity`"))
		#expect(!brief.says("intervals_fetch_streams"))
		#expect(!brief.says("no intensity"))
	}

	@Test func defaultReviewReadsTheChosenActivityByItsListedIdAndMayStateLapMeasurements()
		async throws
	{
		let carried = try await carried()
		let standard = try carried.tier("B", until: "- **Tier C")

		#expect(standard.says("Call `intervals_fetch_activity` with the selected activity's `id`"))
		#expect(standard.says("`laps`"))
		#expect(!standard.says("timing and distance observations only"))
		#expect(carried.rules.says("No depth flag → Tier B"))
	}

	@Test func onlyADeepReviewReadsTheStreamSummary() async throws {
		let carried = try await carried()

		#expect(
			try carried.tier("C", until: "Manual overrides:").says(
				"Call `intervals_fetch_activity` AND `intervals_fetch_streams`"))
		#expect(!carried.rules.says("limit to watts"))
		#expect(try !carried.tier("B", until: "- **Tier C").says("intervals_fetch_streams"))
		#expect(carried.rules.components(separatedBy: "intervals_fetch_streams").count == 3)
		#expect(
			try carried.description(of: .intervalsFetchStreams).says("only for Tier C deep reviews")
		)
	}

	@Test func measurementsAloneNeverEstablishQualityRecoveryReadinessOrPlanCompliance()
		async throws
	{
		let carried = try await carried()
		let streams = try carried.description(of: .intervalsFetchStreams)

		#expect(carried.rules.says("cannot establish session quality, recovery, readiness"))
		#expect(streams.says("cannot establish session quality, recovery, or readiness"))
		#expect(carried.rules.says("never infer plan compliance"))
		#expect(carried.rules.says("Never fabricate intensity, load, plan-compliance"))
		#expect(carried.rules.says("do NOT invent pacing curves or best-efforts"))
		#expect(streams.says("do not use it for pacing"))
	}

	@Test func startIsShownAsTheAthletesLocalTimeAndTheTimeIsLeftOutOfADateOnlyStart()
		async throws
	{
		let carried = try await carried()

		#expect(carried.rules.says("never label it as universal time"))
		#expect(carried.rules.says("leave the time out when the start has a date only"))
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
		#expect(carried.topic.says("append only the rows it supplied"))
		#expect(tables[3] == [["Lap", "Label / kind", "Duration", "Distance"]])
		#expect(carried.topic.says("an average power column and an average HR column"))
		#expect(carried.topic.says("unavailable rather than zero"))
		#expect(carried.rules.says("nullable lap cells as unavailable"))
		for absent in ["sub-sport", "Elapsed", "Timer", "timer", "sequence", "Start ("] {
			#expect(!carried.topic.says(absent), "the review topic names \(absent)")
		}
	}

	@Test func failureRulesNameExactlyTheAnswersAFailedDetailReadGives() async throws {
		let carried = try await carried()
		intervals.activities = [Self.ride, Self.hidden]
		intervals.details[Self.hidden.id] = .hiddenByStrava
		var returned = [
			try await detail(of: "i7654321"), try await detail(of: Self.hidden.id.rawValue),
		]
		#expect(try await detail(of: Self.ride.id.rawValue)["lapsSupplied"] == .bool(false))
		intervals.fail(.activity, with: IntervalsError(code: "http", details: "status 503"))
		returned.append(try await detail(of: Self.ride.id.rawValue))

		let named = carried.rules.matches(of: try Regex("`(activity_[a-z_]+)`")).compactMap {
			$0.output[1].substring.map(String.init)
		}
		#expect(named.sorted() == returned.compactMap { $0["error"]?.stringValue }.sorted())
		#expect(returned.allSatisfy { $0["details"]?.stringValue?.isEmpty == false })
		#expect(carried.rules.says("Never surface the raw error code"))
		#expect(carried.rules.says("`lapsSupplied: false`"))
		for unreachable in ["`Network`", "`Timeout`", "`message`"] {
			#expect(!carried.rules.says(unreachable), "the rules name \(unreachable)")
		}
	}

	@Test func coachStillAsksBeforeLookingFurtherBackReviewingAnOldSessionOrChoosingAMatch()
		async throws
	{
		let rules = try await carried().rules

		#expect(rules.says("`intervals_fetch_activities` for the last 7 days"))
		#expect(rules.says("want me to look further back?"))
		#expect(rules.says("want me to review that?"))
		#expect(rules.says("ask the athlete to clarify before proceeding"))
	}

	@Test func toolDescriptionsSayHowTheIdTravelsAndStateNoLimitThePhoneDoesNotEnforce()
		async throws
	{
		let carried = try await carried()
		let list = try carried.description(of: .intervalsFetchActivities)
		let detail = try carried.description(of: .intervalsFetchActivity)
		let streams = try carried.description(of: .intervalsFetchStreams)

		#expect(list.says("Pass an `id` exactly as listed"))
		for text in [detail, streams] {
			#expect(
				text.says("`id` that `intervals_fetch_activities` listed, passed exactly as listed")
			)
		}
		#expect(streams.says("no per-second data"))
		for tool in [ToolName.intervalsFetchActivity, .intervalsFetchStreams] {
			#expect(try carried.identifierDescription(of: tool).says("Pass exactly as listed."))
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
		let outcome = try await makeOfferedTools(
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
