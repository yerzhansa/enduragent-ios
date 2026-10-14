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
		let request = testRequest([
			WireMessage(role: .system, content: "rules", toolCalls: []),
			WireMessage(role: .user, content: message + "\nCurrent time: 08:00", toolCalls: []),
		])
		func turn(_ calls: [(String, String)], reply: String) -> LiveTurnRecord {
			LiveTurnRecord(
				message: message,
				exchanges: [
					LiveExchange(
						request: request,
						events: calls.enumerated().map { index, call in
							.toolCall(
								WireToolCall(id: "call-\(index)", name: call.0, arguments: call.1))
						}, failure: nil)
				], reply: reply, outcome: "completed", reviewPending: false, calendarWrites: 0)
		}
		let expectations: [LiveExpectation] = [
			.callsWith(.intervalsFetchStreams, argument: "activityId", oneOf: [.string("i5501")]),
			.replyMentions(["Fitness"]),
		]

		let good = turn(
			[("intervals_fetch_streams", #"{"activityId":"i5501"}"#)],
			reply: "Fitness held; the ride started at 08:00 local time.")
		#expect(LiveVerdict.violations(of: good, against: expectations).isEmpty)

		let bad = turn(
			[("intervals_create_workout", "{}"), ("intervals_fetch_streams", "not json")],
			reply: "The ride started at 08:00 UTC.")
		#expect(
			LiveVerdict.violations(of: bad, against: expectations) == [
				"the reply labels a time UTC",
				"calendar tools were called: intervals_create_workout",
				"intervals_fetch_streams was called with arguments that are not JSON",
				#"intervals_fetch_streams was not called with activityId "i5501""#,
				"the reply does not mention Fitness",
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

	@Test(arguments: [
		AmbiguousReviewCase(
			"a Wednesday after a Monday ride and three rides the week before",
			today: "2026-10-14",
			activities: [
				.recorded("i1001", "Easy spin", on: "2026-10-08", at: 6 * 3_600 + 45 * 60),
				.recorded("i1002", "Endurance", on: "2026-10-09", at: 7 * 3_600),
				.recorded("i1003", "Openers", on: "2026-10-10", at: 8 * 3_600),
				.recorded("i1004", "Run off the bike", sport: "Run", on: "2026-10-10", at: 30_300),
				.recorded("i1005", "Threshold", on: "2026-10-12", at: 17 * 3_600 + 30 * 60),
			],
			asks: "/review my ride from Thursday 8 October to Monday 12 October",
			answers: "The \"Openers\" on Saturday 10 October at 08:00.", chosen: "i1003"),
		AmbiguousReviewCase(
			"a Sunday with a ride eight days back left out",
			today: "2026-10-18",
			activities: [
				.recorded("i2001", "Too old", on: "2026-10-11", at: 9 * 3_600),
				.recorded("i2002", "Tempo", on: "2026-10-13", at: 18 * 3_600),
				.recorded("i2003", nil, sport: "VirtualRide", on: "2026-10-17"),
			],
			asks: "/review my ride from Tuesday 13 October to Saturday 17 October",
			answers: "The \"Tempo\" on Tuesday 13 October at 18:00.", chosen: "i2002"),
		AmbiguousReviewCase(
			"two rides on one day and one eight days back",
			today: "2026-10-14",
			activities: [
				.recorded("i3001", "Too old", on: "2026-10-07", at: 9 * 3_600),
				.recorded("i3002", "Commute in", on: "2026-10-13", at: 8 * 3_600),
				.recorded("i3003", "Commute home", on: "2026-10-13", at: 18 * 3_600),
			],
			asks: nil, answers: nil, chosen: nil),
	])
	func theAmbiguousReviewNamesASpanThatHoldsTwoActivitiesOfItsSport(
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
			#expect(
				plan.unavailable.contains(
					"ambiguous review: no sport has activities on two days in the last 7 days"))
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
}
