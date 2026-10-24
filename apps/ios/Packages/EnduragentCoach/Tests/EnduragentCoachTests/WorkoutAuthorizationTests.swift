import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

@Suite(.timeLimit(.minutes(2))) struct WorkoutAuthorizationTests {
	@Test func everyRequestHoldsThePrescriptionRules() async throws {
		let prompts = try await AuthorizationBench.everySystemPrompt()

		for prompt in prompts {
			#expect(
				prompt.contains(
					"## Skill: cycling-prescription-posture\n\n# Cycling Prescription Availability\n"
				))
			for rule in [
				"A request exists only if the current message explicitly asks for a cycling "
					+ "workout or plan, changes to one, or to create, schedule, push, or update a "
					+ "discussed cycling workout.",
				"FTP, availability, equipment, fatigue, goals, race dates, analysis, explanation, "
					+ "review, and status are context only.",
				"- Answer the question. Do not propose, recommend, outline, draft, schedule, or "
					+ "create a workout in prose or with `build_plan_skeleton`, `get_sample_week`, or "
					+ "`prepare_workout_changes`.",
				"Use `prepare_workout_changes` only when the current message asks for calendar "
					+ "creation, scheduling, pushing, or updating; a prose-only request never "
					+ "prepares a calendar change.",
				"Judge each request anew. Earlier requests never carry forward. This covers prose "
					+ "and tool calls.",
			] {
				#expect(prompt.contains(rule), "missing rule: \(rule)")
			}
		}
	}

	@Test func everyRequestHoldsTheWorkoutFamiliesAndTheirStructure() async throws {
		let prompts = try await AuthorizationBench.everySystemPrompt()

		for prompt in prompts {
			#expect(prompt.contains("## Skill: cycling-workout-design\n\n# Workout Design\n"))
			for family in [
				"### Endurance (Z2)\n- Duration: 45min-3h\n- Structure: Steady state in Z2\n",
				"### Tempo (Z3)\n- Duration: 45-90min main set\n- Structure: 2x20min or 3x15min in Z3\n",
				"### Sweet Spot\n- Duration: 45-75min main set\n- Standard formats: 2x20min, 3x15min, 4x10min at the sweet-spot band",
				"### Threshold (Z4)\n- Duration: 30-60min main set\n- Standard formats: 2x20min, 3x10min, 2x15min in Z4\n",
				"### VO2max (Z5)\n- Duration: 15-25min main set\n- Standard formats: 5x4min, 4x5min, 6x3min in Z5\n",
				"### Anaerobic (Z6)\n- Duration: 10-20min total work\n- Standard formats: 8x1min, 6x90s in Z6 with full recovery\n",
				"### Sprint/Neuromuscular (Z7)\n- Duration: 5-10min total work\n- Structure: 6-10x 15-30s all-out efforts",
				"### Recovery (Z1)\n- Duration: 30-45min\n- Structure: Easy spinning in Z1\n",
			] {
				#expect(prompt.contains(family), "missing workout family: \(family)")
			}
			#expect(
				prompt.contains(
					"""
					## Workout Structure Template

					Every workout follows: Warmup → Main Set → Cooldown

					1. **Warmup** (10-15min): Progressive from Z1 to Z2, include 2-3 openers (30s at target intensity)
					2. **Main Set**: The prescribed intervals
					3. **Cooldown** (5-10min): Easy spinning in Z1

					## Progressive Overload Patterns

					- **Duration**: Add 2-5min per interval every 1-2 weeks (e.g., 2x15 → 2x18 → 2x20)
					- **Sets**: Add a set every 2-3 weeks (e.g., 3x10 → 4x10)
					- **Intensity**: Raise target 2-3% FTP per phase
					- **Recovery reduction**: Shorten rest intervals (e.g., 5min → 4min → 3min)

					## Indoor vs Outdoor

					- Indoor: Better for structured intervals (ERG mode), controlled environment
					- Outdoor: Better for long rides, group rides, race simulation
					- Prescribe indoor for: weekday intervals, time-crunched sessions
					- Prescribe outdoor for: weekend long rides, endurance rides
					"""))
		}
	}

	@Test(arguments: [
		"Give me a threshold workout for 45 minutes indoors",
		"Write me an endurance workout for two hours outdoors",
	])
	func proseWorkoutEndingInTextLeavesNoReviewAndAnUnchangedCalendar(request: String)
		async throws
	{
		let bench = AuthorizationBench()
		let workout = "Warm up 10 minutes, then 2x15 minutes in Z4, cool down 5 minutes."
		let coach = try await bench.coach(replying: [.text(workout), .finish(reason: .stop)])

		let settled = try await coach.sendAndSettle(request)

		#expect(replyText(settled) == workout)
		#expect(bench.chatRequests.count == 1)
		try await bench.expectNoReviewAndAnUntouchedCalendar(coach)
	}

	@Test(arguments: ContextOnlyTurn.allCases)
	func contextOnlyTurnLeavesNoReviewAndMakesNoCalendarCall(turn: ContextOnlyTurn)
		async throws
	{
		let bench = AuthorizationBench()
		let coach = try await bench.coach(
			replying: turn.toolCalls + [.text("Noted."), .finish(reason: .stop)])

		let settled = try await coach.sendAndSettle(turn.message)

		#expect(replyText(settled) == "Noted.")
		let toolResults = try #require(bench.chatRequests.last).messages.filter {
			$0.role == .tool
		}
		switch turn {
		case .fatigueReport:
			#expect(bench.chatRequests.count == 1)
		case .newFTP, .newGoal:
			let saved = try MemoryProbe.data(in: try #require(toolResults.first))
			#expect(saved.objectFields["saved"]?.boolValue == true)
		case .activityReview:
			#expect(toolResults.count == 1)
			#expect(
				bench.intervals.calls.contains {
					if case .activity = $0 { return true }
					return false
				})
		}
		try await bench.expectNoReviewAndAnUntouchedCalendar(coach)
	}
}

enum ContextOnlyTurn: CaseIterable {
	case fatigueReport
	case newFTP
	case newGoal
	case activityReview

	var message: String {
		switch self {
		case .fatigueReport: "My legs are heavy and I slept badly all week"
		case .newFTP: "My FTP is now 265 W"
		case .newGoal: "My new goal is the Alpine gran fondo in September"
		case .activityReview: "How did my ride on Thursday go?"
		}
	}

	var toolCalls: [ScriptedEvent] {
		switch self {
		case .fatigueReport: []
		case .newFTP:
			[
				.toolCall(
					name: "memory_write",
					arguments:
						#"{"type":"memory","section":"cycling-profile","content":"- FTP 265 W"}"#),
				.finish(reason: .toolCalls),
			]
		case .newGoal:
			[
				.toolCall(
					name: "memory_write",
					arguments:
						#"{"type":"memory","section":"goals","content":"- Alpine gran fondo in September"}"#
				),
				.finish(reason: .toolCalls),
			]
		case .activityReview:
			[
				.toolCall(
					name: "intervals_fetch_activity", arguments: #"{"activityId":"i1234567"}"#),
				.finish(reason: .toolCalls),
			]
		}
	}
}

struct AuthorizationBench {
	static let planned = CalendarEvent(
		description: "- 60m 65%", type: "Ride", id: EventID(rawValue: 42),
		startDateLocal: "1998-06-14T00:00:00", name: "Endurance", category: "WORKOUT",
		externalId: nil, uid: nil, tags: [IntervalsPolicy.coachTag], coachCreated: true)

	let transport = FakeModelTransport()
	let intervals = FakeIntervalsClient(athleteName: "Ada", ftp: 250)
	let store = InMemoryRecordLog()
	let clock = FixedClock(now: "1998-06-13T08:00:00+02:00", timeZone: "Europe/Amsterdam")

	init() {
		intervals.events = [Self.planned]
	}

	var chatRequests: [CompletionRequest] { sent(.chatAttempt, by: transport) }

	static func everySystemPrompt() async throws -> [String] {
		let connected = AuthorizationBench()
		let scheduling = try await connected.coach(replying: [
			.text("Warm up, 2x15 minutes in Z4, cool down."), .finish(reason: .stop),
			.toolCall(
				name: ToolName.prepareWorkoutChanges.rawValue,
				arguments:
					#"{"preparation":{"kind":"complete","changes":[\#(PreparationFixture.ride(on: "1998-06-14"))]}}"#
			),
			.finish(reason: .toolCalls),
			.text("Ready for your approval."), .finish(reason: .stop),
		])
		_ = try await scheduling.sendAndSettle("Give me a threshold workout")
		_ = try await scheduling.sendAndSettle("Add it to my calendar for tomorrow")
		let unconnected = AuthorizationBench()
		let prose = try await unconnected.coach(
			connected: false, replying: [.text("Warm up, then ride."), .finish(reason: .stop)])
		_ = try await prose.sendAndSettle("Give me a threshold workout")

		let requests = connected.chatRequests + unconnected.chatRequests
		#expect(connected.chatRequests.count == 3)
		#expect(unconnected.chatRequests.count == 1)
		return try requests.map { request in
			let system = try #require(request.messages.first)
			#expect(system.role == .system)
			#expect(request.messages.filter { $0.role == .system }.count == 1)
			return system.content
		}
	}

	func coach(connected: Bool = true, replying script: [ScriptedEvent]) async throws -> Coach {
		transport.respond = ScriptedReply.sequence(
			script, for: .chat, otherwise: transport.respond)
		let secrets = ICloudKeychainStore(backing: FixtureSecretStoreBacking())
		try secrets.storeCreditsAccount(CreditsAccount(appAccountToken: UUID(), key: testKey))
		if connected { try secrets.storeIntervalsConnection(testConnection) }
		return await makeCoach(
			transport: transport, intervals: intervals, store: store, clock: clock,
			secrets: secrets)
	}

	func savedReviews() async throws -> Int {
		try await store.fetch(RecordQuery(scope: .deviceLocal([.workoutReview]))).records.count
	}

	func expectNoReviewAndAnUntouchedCalendar(_ coach: Coach) async throws {
		#expect(try #require(await coach.currentSnapshot(.main)).review == nil)
		#expect(try await savedReviews() == 0)
		#expect(intervals.calls.filter(\.isCalendarCall).isEmpty)
		#expect(intervals.events == [Self.planned])
	}
}
