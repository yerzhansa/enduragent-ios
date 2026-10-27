import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

@Suite struct PreparationToolTests {
	let transport = FakeModelTransport()
	let intervals = FakeIntervalsClient(athleteName: "Ada", ftp: 250)
	let store = InMemoryRecordLog()
	let auckland = FixedClock(now: "1998-09-08T00:30:00+12:00", timeZone: "Pacific/Auckland")

	enum Answer: Equatable, Sendable {
		case prepared(Int)
		case refused(String)
	}

	struct AucklandCase: Sendable, CustomTestStringConvertible {
		let label: String
		let change: String
		let answer: Answer

		var testDescription: String { label }
	}

	static let aucklandCases: [AucklandCase] = [
		AucklandCase(
			label: "edit today", change: #"{"kind":"edit","eventId":201,"patch":{"name":"Tempo"}}"#,
			answer: .prepared(1)),
		AucklandCase(
			label: "delete today", change: #"{"kind":"delete","eventId":201}"#,
			answer: .prepared(1)),
		AucklandCase(
			label: "edit yesterday",
			change: #"{"kind":"edit","eventId":202,"patch":{"name":"Tempo"}}"#,
			answer: .refused("past_workout_protected")),
		AucklandCase(
			label: "delete yesterday", change: #"{"kind":"delete","eventId":202}"#,
			answer: .refused("past_workout_protected")),
		AucklandCase(
			label: "ride yesterday", change: PreparationFixture.ride(on: "1998-09-07"),
			answer: .refused("past_date_refused")),
		AucklandCase(
			label: "strength yesterday", change: PreparationFixture.strength(on: "1998-09-07"),
			answer: .refused("past_date_refused")),
		AucklandCase(
			label: "ride today", change: PreparationFixture.ride(on: "1998-09-08"),
			answer: .prepared(1)),
		AucklandCase(
			label: "strength today", change: PreparationFixture.strength(on: "1998-09-08"),
			answer: .prepared(1)),
		AucklandCase(
			label: "athlete workout", change: #"{"kind":"delete","eventId":203}"#,
			answer: .refused("not_coach_created")),
		AucklandCase(
			label: "race", change: #"{"kind":"delete","eventId":204}"#,
			answer: .refused("not_a_workout")),
		AucklandCase(
			label: "note", change: #"{"kind":"delete","eventId":205}"#,
			answer: .refused("not_a_workout")),
		AucklandCase(
			label: "move to yesterday",
			change: #"{"kind":"edit","eventId":201,"patch":{"date":"1998-09-07"}}"#,
			answer: .refused("past_workout_destination")),
	]

	@Test(arguments: aucklandCases)
	func eligibilityFollowsTheAthletesDayNotUTC(_ example: AucklandCase) async throws {
		intervals.events = [
			PreparationFixture.workout(201, on: "1998-09-08"),
			PreparationFixture.workout(202, on: "1998-09-07"),
			PreparationFixture.workout(203, on: "1998-09-08", owned: false),
			PreparationFixture.workout(204, on: "1998-09-08", category: "RACE_A"),
			PreparationFixture.workout(205, on: "1998-09-08", category: "NOTE"),
		]
		let coach = await makeCoach(
			transport: transport, intervals: intervals, store: store, clock: auckland)

		let results = try await answers(
			to: [prepare(#"{"kind":"complete","changes":[\#(example.change)]}"#)], from: coach)

		#expect(results == [example.answer])
		#expect(intervals.calls.allSatisfy { !$0.isWrite })
	}

	@Test func aMixedRequestIsPreparedWithoutACalendarWriteOrAnOldProposal() async throws {
		intervals.events = [
			PreparationFixture.workout(201, on: "1998-09-10"),
			PreparationFixture.workout(202, on: "1998-09-11"),
		]
		let coach = await makeCoach(
			transport: transport, intervals: intervals, store: store, clock: auckland)

		let results = try await answers(
			to: [
				prepare(
					#"{"kind":"complete","changes":[\#(PreparationFixture.ride(on: "1998-09-09")),\#(PreparationFixture.strength(on: "1998-09-10")),{"kind":"edit","eventId":201,"patch":{"durationSeconds":4500}},{"kind":"delete","eventId":202}]}"#
				)
			], from: coach)

		#expect(results == [.prepared(4)])
		#expect(intervals.calls.allSatisfy { !$0.isWrite })
		#expect(
			try await store.fetch(RecordQuery(scope: LegacyReviewRecords.localScope)).records
				.isEmpty)
		#expect(
			try await store.fetch(RecordQuery(scope: LegacyReviewRecords.syncedScope)).records
				.isEmpty)
	}

	@Test func pendingAnswersNoneWhileOnlyADraftExists() async throws {
		let coach = await makeCoach(
			transport: transport, intervals: intervals, store: store, clock: auckland)

		let data = try await toolData(
			for: [
				prepare(
					#"{"kind":"complete","changes":[\#(PreparationFixture.ride(on: "1998-09-09"))]}"#
				),
				.finish(reason: .toolCalls),
				.toolCall(name: "get_pending_workout_changes", arguments: "{}"),
			], from: coach)

		#expect(data.first?.objectFields["kind"] == .string("prepared"))
		#expect(data.last == .object(["kind": .string("none")]))
	}

	@Test func pendingReadsTheWaitingReviewWithItsOwnItemIds() async throws {
		let review = try reviewFixture("workout-review-approval")
		let clock = FixedClock(now: "1998-06-13T08:00:00+02:00", timeZone: "Europe/Amsterdam")
		_ = try await Ledger(log: store, clock: clock, diagnostics: DiagnosticsLog(clock: clock))
			.commit(
				review: review,
				stamp: testStamp(operation: .workoutReview(review.id, review.revision)),
				after: .empty)
		let coach = await makeCoach(
			transport: transport, intervals: intervals, store: store, clock: clock)

		let pending = try #require(
			try await toolData(
				for: [.toolCall(name: "get_pending_workout_changes", arguments: "{}")], from: coach
			).first)

		let fields = pending.objectFields
		#expect(fields["kind"] == .string("pending"))
		#expect(
			fields["reference"]
				== .object([
					"setId": .string("00T47DW5000000000000000100"), "revision": .number(1),
				]))
		#expect(fields["completedCount"] == .number(0))
		let changes = try #require(fields["changes"]?.arrayValue)
		#expect(
			changes.map { $0.objectFields["id"] }
				== ["401", "402", "403"].map { .string("00T47DW5000000000000000\($0)") })
		#expect(
			changes.map { $0.objectFields["change"]?.objectFields["eventId"] }
				== [nil, .number(101), .number(102)])
	}

	@Test func anUnreadablePendingReviewIsRecordedAsAToolFailure() async throws {
		let failing = FaultInjectingRecordLog(wrapping: store)
		transport.respond = ScriptedReply.sequence(
			[
				.toolCall(name: "get_pending_workout_changes", arguments: "{}"),
				.finish(reason: .toolCalls),
				.text("I could not read it."),
				.finish(reason: .stop),
			], otherwise: transport.respond)
		let coach = await makeCoach(
			transport: transport, intervals: intervals, store: failing, clock: auckland)
		#expect(try #require(await coach.currentSnapshot(.main)).review == nil)
		failing.failNextFetch(in: .deviceLocal([.workoutReview]))

		#expect(replyText(try await coach.sendAndSettle("Plan my week")) == "I could not read it.")

		let followUp = try #require(transport.requests.last)
		let toolMessage = try #require(followUp.messages.last(where: { $0.role == .tool }))
		#expect(toolMessage.content == ToolFault.saveFailed.json.canonicalDigestInput())
		let failures = coach.diagnostics.entries.compactMap { entry -> ToolFault? in
			guard
				case .toolFailed(
					transport.requests[0].attempt, .getPendingWorkoutChanges, let failure) = entry
					.event
			else { return nil }
			return failure
		}
		#expect(failures == [.saveFailed])
	}

	@Test(arguments: [
		#"{"preparation":{"kind":"incomplete","reason":"No slot"},"extra":true}"#,
		#"{"preparation":{"kind":"incomplete","reason":"No slot","changes":[]}}"#,
		#"{"preparation":{"kind":"complete","base":{"setId":"00T47DW5000000000000000100","revision":1},"changes":[{"kind":"delete","eventId":201}]}}"#,
		#"{"preparation":{"kind":"replace","base":{"setId":"00T47DW5000000000000000100","revision":1},"changes":[{"kind":"delete","eventId":201}],"replacements":[{"id":"00T47DW5000000000000000401","change":{"kind":"delete","eventId":201}}]}}"#,
		#"{"preparation":{"kind":"revise","base":{"setId":"00T47DW5000000000000000100","revision":1},"replacements":[{"id":"00T47DW5000000000000000401","change":{"kind":"delete","eventId":201}}],"changes":[{"kind":"delete","eventId":201}]}}"#,
		#"{"preparation":{"kind":"complete","changes":[{"kind":"add-cycling","date":"1998-09-09","name":"Ride","workout":{"name":"Ride","steps":[]}}]}}"#,
		#"{"preparation":{"kind":"complete","changes":[{"kind":"add-strength","date":"1998-09-09","name":"Core","durationMinutes":30,"effort":"Easy","description":"Plank","workout":{}}]}}"#,
		#"{"preparation":{"kind":"complete","changes":[{"kind":"edit","eventId":201,"patch":{"name":"Tempo"},"date":"1998-09-09"}]}}"#,
		#"{"preparation":{"kind":"complete","changes":[{"kind":"delete","eventId":201,"patch":{}}]}}"#,
		#"{"preparation":{"kind":"revise","base":{"setId":"00T47DW5000000000000000100","revision":1,"items":2},"replacements":[{"id":"00T47DW5000000000000000401","change":{"kind":"delete","eventId":201}}]}}"#,
		#"{"preparation":{"kind":"revise","base":{"setId":"00T47DW5000000000000000100","revision":1},"replacements":[{"id":"00T47DW5000000000000000401","eventId":201,"change":{"kind":"delete","eventId":201}}]}}"#,
	])
	func anUnknownFieldIsRefusedForEveryShape(_ arguments: String) async throws {
		intervals.events = [PreparationFixture.workout(201, on: "1998-09-10")]
		let coach = await makeCoach(
			transport: transport, intervals: intervals, store: store, clock: auckland)

		let data = try #require(
			try await toolData(
				for: [.toolCall(name: "prepare_workout_changes", arguments: arguments)], from: coach
			).first)

		#expect(data.objectFields["error"] == .string("invalid_input"))
		#expect(data.objectFields["details"]?.stringValue?.contains("has an unknown field") == true)
		#expect(intervals.calls.allSatisfy { !$0.isCalendarCall })
	}

	@Test func aReviewTurnIsOfferedThePreparationToolsInsteadOfTheGatedOnes() async throws {
		transport.respond = ScriptedReply.sequence(
			[.text("Easy spin today."), .finish(reason: .stop)], otherwise: transport.respond)
		let coach = await makeCoach(
			transport: transport, intervals: intervals, store: store, clock: auckland)

		_ = try await coach.sendAndSettle("What should I ride?")

		#expect(
			try #require(transport.requests.first).tools.map(\.name) == [
				.calculateZones, .buildPlanSkeleton, .assessFeasibility, .getSampleWeek,
				.intervalsFetchAthlete, .intervalsFetchWellness, .intervalsFetchActivity,
				.intervalsFetchStreams, .intervalsFetchActivities, .intervalsListEvents,
				.getPendingWorkoutChanges, .prepareWorkoutChanges, .memoryQuery, .memoryWrite,
				.ledgerAppend, .planSave, .planLoad,
			])
	}

	@Test func refusalsReachTheModelWithoutSwiftTypeNames() async throws {
		intervals.fail(
			.wellness, with: IntervalsError(code: "http", details: "status 503", status: 503))
		let coach = await makeCoach(
			transport: transport, intervals: intervals, store: store, clock: auckland)
		transport.respond = ScriptedReply.sequence(
			[
				prepare(
					PreparedRideBoundsTests.oneRide(
						steps: [#"{"type":"ramp","duration":{"value":10,"unit":"minutes"}}"#])),
				.toolCall(
					name: "intervals_fetch_wellness",
					arguments: #"{"oldest":"1998-09-01","newest":"1998-09-07"}"#),
				.finish(reason: .toolCalls), .text("Ready."), .finish(reason: .stop),
			], otherwise: transport.respond)

		#expect(replyText(try await coach.sendAndSettle("Plan my week")) == "Ready.")

		let results = try #require(transport.requests.last).messages.filter { $0.role == .tool }
			.map(\.content)
		for result in results {
			for typeName in ["IntervalsError", "InvalidWorkout", "EnduragentCoach", "Optional("] {
				#expect(!result.contains(typeName), "\(typeName) in \(result)")
			}
		}
		let details = try results.map { content in
			let json = try JSONValue.parse(content)
			return (json.objectFields["data"] ?? json).objectFields["details"]?.stringValue
		}
		#expect(
			details == [
				"preparation.changes[0]: steps[0]: ramp step requires a power target", "status 503",
			])
	}

	private func prepare(_ preparation: String) -> ScriptedEvent {
		.toolCall(name: "prepare_workout_changes", arguments: #"{"preparation":\#(preparation)}"#)
	}

	private func answers(to calls: [ScriptedEvent], from coach: Coach) async throws -> [Answer] {
		try await toolData(for: calls, from: coach).map { data in
			let fields = data.objectFields
			if let code = fields["error"]?.stringValue { return .refused(code) }
			#expect(fields["kind"] == .string("prepared"))
			return .prepared(Int(try #require(fields["changeCount"]?.numberValue)))
		}
	}

	private func toolData(for calls: [ScriptedEvent], from coach: Coach) async throws
		-> [JSONValue]
	{
		transport.respond = ScriptedReply.sequence(
			calls + [.finish(reason: .toolCalls), .text("Ready."), .finish(reason: .stop)],
			otherwise: transport.respond)
		#expect(replyText(try await coach.sendAndSettle("Plan my week")) == "Ready.")
		return try #require(transport.requests.last).messages.filter { $0.role == .tool }.map {
			try #require(try JSONValue.parse($0.content).objectFields["data"])
		}
	}
}
