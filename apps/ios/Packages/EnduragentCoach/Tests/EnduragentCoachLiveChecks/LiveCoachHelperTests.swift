import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

@Suite struct LiveCoachHelperTests {
	static func planForAnEmptyAccount() throws -> LiveCoachPlan {
		let today = try #require(CivilDate(rawValue: "1998-06-13"))
		return LiveCoachPlan(
			listing: ActivityListing(
				range: try ReadRange(oldest: today.adding(days: -29), newest: today, today: today),
				rows: []),
			today: today)
	}

	@Test func theVerdictNamesMissedToolCallsCalendarCallsAndAUTCStart() throws {
		let message = "/review deep the ride"
		func turn(
			_ calls: [(String, String)], reply: String, sent: String? = nil,
			offered: [ToolName] = [], reviewPending: Bool = false
		) -> LiveTurnRecord {
			let request = testRequest(
				[
					WireMessage(role: .system, content: "rules", toolCalls: []),
					WireMessage(
						role: .user, content: (sent ?? message) + "\nCurrent time: 08:00",
						toolCalls: []),
				],
				tools: offered.map { ToolSchema(name: $0, description: "", parameters: .null) })
			return LiveTurnRecord(
				message: message,
				exchanges: [
					LiveExchange(
						request: request,
						events: calls.enumerated().map { index, call in
							.toolCall(
								WireToolCall(id: "call-\(index)", name: call.0, arguments: call.1))
						}, failure: nil)
				], reply: reply, outcome: "completed", reviewPending: reviewPending,
				calendarWrites: 0)
		}
		let expectations: [LiveExpectation] = [
			.callsWith(.intervalsFetchStreams, argument: "activityId", oneOf: [.string("i5501")]),
			.replyMentions(["Fitness"]),
		]
		let today = try #require(CivilDate(rawValue: "1998-06-13"))
		let tenth = try #require(CivilDate(rawValue: "1998-06-10"))
		let unmet: [LiveExpectation] = [
			.neverCalls(.intervalsFetchStreams),
			.listsActivitiesCovering(tenth, today: today),
			.offersNoTrainingTools,
			.promptHolds("Training data is not connected."),
		]

		let good = turn(
			[("intervals_fetch_streams", #"{"activityId":"i5501"}"#)],
			reply: "Fitness held; the ride started at 08:00 local time.")
		#expect(LiveVerdict.violations(of: good, against: expectations).isEmpty)

		let bad = turn(
			[
				("intervals_create_workout", "{}"), ("intervals_fetch_streams", "not json"),
				("intervals_fetch_activities", #"{"oldest":"1998-06-11","newest":"1998-06-12"}"#),
			],
			reply: "The ride started at 08:00 UTC.", sent: "/review the ride",
			offered: [.intervalsFetchAthlete], reviewPending: true)
		#expect(
			LiveVerdict.violations(of: bad, against: expectations + unmet) == [
				"the coach did not receive the athlete's message unchanged",
				"the reply labels a time UTC",
				"calendar tools were called: intervals_create_workout",
				"a workout review is waiting",
				"intervals_fetch_streams was called with arguments that are not JSON",
				#"intervals_fetch_streams was not called with activityId "i5501""#,
				"the reply does not mention Fitness",
				"intervals_fetch_streams was called",
				"no activity list covered 1998-06-10",
				"training tools were offered: intervals_fetch_athlete",
				"the prompt does not hold \"Training data is not connected.\"",
			])
	}

	@Test func everyScenarioTheAccountCannotStageFailsTheCoachRun() throws {
		let plan = try Self.planForAnEmptyAccount()

		let report = LiveCoachReport(unavailable: plan.unavailable, spentBefore: 0)

		#expect(plan.unavailable.count == 3)
		#expect(
			report.failures(capReached: false)
				== plan.unavailable.map { "not available, so not covered: \($0)" })
	}

	@Test func aScenarioThatNeverPassedAndASpendCapStopEachFailTheCoachRun() {
		func run(_ attempt: Int, _ violations: [String]) -> LiveScenarioRun {
			LiveScenarioRun(attempt: attempt, turns: [], violations: violations, transcript: "")
		}
		var report = LiveCoachReport(unavailable: [], spentBefore: 0)
		report.results = [
			(
				"status",
				[
					run(1, ["the reply does not mention Form"]),
					run(2, ["the reply does not mention Fatigue"]),
				]
			),
			(
				"workout",
				[run(1, ["calendar tools were called: intervals_create_workout"]), run(2, [])]
			),
			("zones", [run(1, [])]),
			("review-brief", [run(1, ["intervals_fetch_activity was not called"])]),
		]
		report.stoppedBefore = "review-deep"

		let failed = [
			"status: run 1: the reply does not mention Form; run 2: the reply does not mention Fatigue",
			"review-brief: run 1: intervals_fetch_activity was not called",
		]
		#expect(report.failures(capReached: false) == failed)
		#expect(
			report.failures(capReached: true)
				== failed + ["The spend cap stopped the suite before review-deep."])
	}

	@Test(arguments: [
		AmbiguousReviewCase(
			"the seeded account on Wednesday 14 October", today: "2026-10-14",
			activities: AmbiguousReviewCase.seeded(anchor: "2026-10-14"),
			asks: "/review my ride on Saturday 10 October",
			answers: "The \"[synthetic] Afternoon recovery spin\" on Saturday 10 October at 16:00.",
			chosen: "i4024"),
		AmbiguousReviewCase(
			"a Sunday with a ride and a virtual ride on one day, and rides 20 minutes apart later",
			today: "2026-10-18",
			activities: [
				.recorded("i2001", "Commute in", on: "2026-10-13", at: 8 * 3_600),
				.recorded(
					"i2002", "Zwift race", sport: "VirtualRide", on: "2026-10-13", at: 19 * 3_600),
				.recorded("i2003", "Group ride", on: "2026-10-16", at: 7 * 3_600),
				.recorded("i2004", "Coffee spin", on: "2026-10-16", at: 7 * 3_600 + 20 * 60),
				.recorded("i2005", "Easy run", sport: "Run", on: "2026-10-17", at: 6 * 3_600),
				.recorded("i2006", "Strides", sport: "Run", on: "2026-10-17", at: 18 * 3_600),
			],
			asks: "/review my ride on Tuesday 13 October",
			answers: "The \"Zwift race\" on Tuesday 13 October at 19:00.", chosen: "i2002"),
		AmbiguousReviewCase(
			"two rides 31 minutes apart", today: "2026-10-14",
			activities: [
				.recorded("i3001", "Commute in", on: "2026-10-13", at: 8 * 3_600),
				.recorded("i3002", "Errand", on: "2026-10-13", at: 8 * 3_600 + 31 * 60),
			],
			asks: "/review my ride on Tuesday 13 October",
			answers: "The \"Errand\" on Tuesday 13 October at 08:31.", chosen: "i3002"),
		AmbiguousReviewCase(
			"rides on separate days, a ride and run linking two rides, rides 30 minutes apart, untimed rides, and a pair eight days back",
			today: "2026-10-14",
			activities: [
				.recorded("i4001", "Too old", on: "2026-10-07", at: 8 * 3_600),
				.recorded("i4002", "Too old too", on: "2026-10-07", at: 18 * 3_600),
				.recorded("i4003", "Untimed", on: "2026-10-09"),
				.recorded("i4004", "Untimed too", on: "2026-10-09"),
				.recorded("i4005", "Brick ride", on: "2026-10-11", at: 7 * 3_600),
				.recorded(
					"i4006", "Brick run", sport: "Run", on: "2026-10-11", at: 7 * 3_600 + 25 * 60),
				.recorded("i4007", "Brick ride two", on: "2026-10-11", at: 7 * 3_600 + 50 * 60),
				.recorded("i4008", "Commute in", on: "2026-10-12", at: 8 * 3_600),
				.recorded("i4009", "Commute home", on: "2026-10-12", at: 8 * 3_600 + 30 * 60),
				.recorded("i4010", "Endurance", on: "2026-10-13", at: 7 * 3_600),
			],
			asks: nil, answers: nil, chosen: nil),
	])
	func theAmbiguousReviewNamesOneDayWithTwoSeparateActivitiesOfItsSport(
		sample: AmbiguousReviewCase
	) throws {
		let today = try #require(CivilDate(rawValue: sample.today))
		let plan = LiveCoachPlan(
			listing: ActivityListing(
				range: try ReadRange(oldest: today.adding(days: -29), newest: today, today: today),
				rows: sample.activities.map(ActivityRow.activity)),
			today: today)

		let scenario = plan.scenarios.first { $0.name == "review-ambiguous" }

		guard let asks = sample.asks, let answers = sample.answers, let chosen = sample.chosen
		else {
			#expect(scenario == nil)
			#expect(plan.unavailable.contains(LiveCoachPlan.noAmbiguousDay))
			return
		}
		let turns = try #require(scenario).turns
		#expect(turns.map(\.message) == [asks, answers])
		#expect(turns.first?.expectations.contains(.neverCalls(.intervalsFetchActivity)) == true)
		#expect(
			turns.last?.expectations.last
				== .callsWith(
					.intervalsFetchActivity, argument: "activityId", oneOf: [.string(chosen)]))
	}

	@Test func aConnectedTurnAnsweredOnTheFallbackSnapshotFails() throws {
		let plan = try Self.planForAnEmptyAccount()
		let status = try #require(plan.scenarios.first { $0.name == "status" })
		let expectations = try #require(status.turns.first).expectations
		func turn(prompt: String) -> LiveTurnRecord {
			let request = testRequest([
				WireMessage(role: .system, content: prompt, toolCalls: []),
				WireMessage(role: .user, content: "/status\nCurrent time: 08:00", toolCalls: []),
			])
			return LiveTurnRecord(
				message: "/status",
				exchanges: [LiveExchange(request: request, events: [], failure: nil)],
				reply: "Fitness 55, Fatigue 42, Form +13.", outcome: "completed",
				reviewPending: false, calendarWrites: 0)
		}

		let read = turn(prompt: PromptStaticBlocks.snapshotHeading + "\n\nProfile: FTP 250 W")
		#expect(LiveVerdict.violations(of: read, against: expectations).isEmpty)
		let fallback = turn(prompt: PromptStaticBlocks.snapshotFallback)
		#expect(
			LiveVerdict.violations(of: fallback, against: expectations) == [
				"the prompt holds \"\(PromptStaticBlocks.snapshotFallback)\""
			])
	}

	@Test func theReadOnlyTrainingRefusesEveryWriteWithoutReachingTheAccount() async throws {
		let account = FakeIntervalsClient(athleteName: "Ada", ftp: 250)
		let writes = LiveCalendarWrites()
		let training = LiveReadOnlyTraining(inner: account, writes: writes)
		let refused = IntervalsError(
			code: "live_check_read_only", details: "The live check never writes the calendar.")
		let draft = ChatCalendarCreate(
			date: "1998-06-14", name: "Z2 Endurance 60min", description: "- 60m 65%", type: .ride,
			externalId: IntervalsSerializer.chatExternalId(
				date: "1998-06-14", name: "Z2 Endurance 60min"),
			tags: [IntervalsPolicy.coachTag])

		await #expect(throws: refused) { _ = try await training.createChatEvent(draft) }
		await #expect(throws: refused) {
			_ = try await training.updateEvent(
				id: EventID(rawValue: 7), name: "Z2", description: nil, date: nil)
		}
		await #expect(throws: refused) { try await training.deleteEvent(id: EventID(rawValue: 7)) }

		#expect(writes.total == 3)
		#expect(account.calls.isEmpty)
		#expect(account.events.isEmpty)
		let written = LiveTurnRecord(
			message: "/status", exchanges: [], reply: "Done.", outcome: "completed",
			reviewPending: false, calendarWrites: writes.total)
		#expect(
			LiveVerdict.violations(of: written, against: []).contains("the calendar was written"))
	}

	@Test func theReadsFailingStateConfirmsTheConnectionAndThenFailsBothSnapshotReads()
		async throws
	{
		let today = try #require(CivilDate(rawValue: "1998-06-13"))
		let model = FakeModelTransport(
			respond: ScriptedReply.sequence([.text("Ride easy today."), .finish(reason: .stop)]))
		let bench = LiveCoachBench(
			intervalsKey: "synthetic-intervals-key", openRouterKey: "synthetic-model-key",
			athlete: nil, model: try LiveCoachBench.builtInModel(),
			ledger: try LiveSpendLedger(
				file: try TestTemporaryFolders.make().appending(path: "spend.tsv"), limit: 10),
			today: today, modelTransport: { _ in model },
			accountReads: { _, _, _ in FakeIntervalsClient(athleteName: "Ada", ftp: 250) })
		let plan = try Self.planForAnEmptyAccount()
		let scenario = try #require(plan.scenarios.first { $0.setting == .readsFailing })

		let run = try await bench.run(scenario, attempt: 1)

		#expect(run.violations.isEmpty)
		#expect(run.turns.map(\.outcome) == ["completed"])
		#expect(run.turns.first?.reply == "Ride easy today.")
	}

	@Test func theSpendStatementReadsTheTotalAcrossRunsAgainstTheLimitAndNamesTheCapStop()
		throws
	{
		let file = try TestTemporaryFolders.make().appending(path: "spend.tsv")
		let first = try LiveSpendLedger(file: file, limit: LiveSpendLedger.unitLimit)
		try first.charge(
			model: testModel, usage: Usage(inputTokens: 900, outputTokens: 80, cost: 9.6), bound: 1,
			at: Date(timeIntervalSince1970: 899_164_800))
		let second = try LiveSpendLedger(file: file, limit: LiveSpendLedger.unitLimit)

		#expect(second.statement == "Model spend total: $9.600000 of $10.00.")
		#expect(throws: ProviderFailure.accessExhausted) { try second.admit(0.5) }
		#expect(
			second.statement == "Model spend total: $9.600000 of $10.00; the cap stopped the suite."
		)
	}
}

struct AmbiguousReviewCase: Sendable, CustomTestStringConvertible {
	let testDescription: String
	let today: String
	let activities: [Activity]
	let asks: String?
	let answers: String?
	let chosen: String?

	init(
		_ testDescription: String, today: String, activities: [Activity], asks: String?,
		answers: String?, chosen: String?
	) {
		self.testDescription = testDescription
		self.today = today
		self.activities = activities
		self.asks = asks
		self.answers = answers
		self.chosen = chosen
	}

	static func seeded(anchor: CivilDate) -> [Activity] {
		LiveSeedPlan(anchor: anchor).activities.enumerated().map { position, activity in
			.recorded(
				"i\(4_000 + position)", activity.name,
				sport: activity.sport == .ride ? "Ride" : "Run", on: activity.start.date,
				at: activity.start.secondOfDay)
		}
	}
}
