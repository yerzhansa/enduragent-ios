import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

@Suite struct ToolOfferTests {
	let transport = FakeModelTransport()
	let intervals = FakeIntervalsClient(athleteName: "Ada", ftp: 250)
	let store = InMemoryRecordLog()
	let clock = FixedClock(now: "1998-06-13T08:00:00+02:00", timeZone: "Europe/Amsterdam")

	@Test func unconnectedTurnIsOfferedLocalToolsAndMemoryReadOnlyOnceMemoryIsHidden()
		async throws
	{
		transport.respond = ScriptedReply.sequence(
			[
				.toolCall(
					name: "memory_write",
					arguments: #"{"type":"memory","section":"notes","content":"- Hill repeats"}"#),
				.finish(reason: .toolCalls), .text("Saved."), .finish(reason: .stop),
				.text("Noted."), .finish(reason: .stop),
			], otherwise: transport.respond)
		let coach = await unconnectedCoach()

		_ = try await coach.sendAndSettle("Remember I like hill repeats")
		_ = try await coach.sendAndSettle("Thanks")

		let offered = sent(.chatAttempt, by: transport).map { $0.tools.map(\.name) }
		#expect(
			offered.first == [
				.calculateZones, .buildPlanSkeleton, .assessFeasibility, .getSampleWeek,
				.memoryQuery, .memoryWrite, .ledgerAppend,
			])
		#expect(
			offered.last == [
				.calculateZones, .buildPlanSkeleton, .assessFeasibility, .getSampleWeek,
				.memoryRead, .memoryQuery, .memoryWrite, .ledgerAppend,
			])
	}

	@Test func connectedTurnIsOfferedEveryToolInOneOrder() async throws {
		transport.respond = ScriptedReply.sequence(
			[.text("Easy spin today."), .finish(reason: .stop)], otherwise: transport.respond)
		let coach = await makeCoach(
			transport: transport, intervals: intervals, store: store, clock: clock)

		_ = try await coach.sendAndSettle("What should I ride?")

		#expect(
			try #require(transport.requests.first).tools.map(\.name) == [
				.calculateZones, .buildPlanSkeleton, .assessFeasibility, .getSampleWeek,
				.intervalsFetchAthlete, .intervalsFetchWellness, .intervalsFetchActivity,
				.intervalsFetchStreams, .intervalsFetchActivities, .intervalsListEvents,
				.getPendingWorkoutChanges, .prepareWorkoutChanges, .memoryQuery, .memoryWrite,
				.ledgerAppend,
			])
	}

	@Test func everyToolAConnectedTurnCanOfferTakesItsPinnedParameters() throws {
		let offer = makeToolOffer(
			training: connectedTraining(intervals),
			ledger: Ledger(log: store, clock: clock, diagnostics: DiagnosticsLog(clock: clock)),
			clock: clock,
			memory: MemoryView(
				sections: ["notes": "stamp\n- Prefers hill repeats"], todayNotes: nil,
				orphanNames: []))
		let pinned = try JSONValue.parse(
			String(decoding: try fixtureData("offered-tool-parameters"), as: UTF8.self))

		#expect(
			JSONValue.object(
				Dictionary(
					uniqueKeysWithValues: offer.schemas.map { ($0.name.rawValue, $0.parameters) })
			) == pinned)
	}

	@Test func everyToolIsDefinedUnderTheNameItsEffectCarries() {
		let defined = ToolName.allCases.compactMap { name in
			CoachTools.definition(of: name).map { (name: name, effect: $0.effect) }
		}

		#expect(defined.map(\.name) == ToolName.allCases.filter { $0 != .planSave })
		for (name, effect) in defined {
			#expect(effect.name == name, "\(name)")
		}
	}

	@Test func unconnectedPromptSaysTrainingDataIsNotConnected() async throws {
		transport.respond = ScriptedReply.sequence(
			[.text("Easy spin today."), .finish(reason: .stop)], otherwise: transport.respond)
		let coach = await unconnectedCoach()

		_ = try await coach.sendAndSettle("How is my form?")

		let system = try #require(transport.requests.first?.messages.first?.content)
		#expect(
			system.contains(
				PromptAssembly.snapshotSection(.notConnected) + PromptAssembly.sectionSeparator))
		#expect(!system.contains("fetch the profile and latest wellness before prescribing"))
	}

	@Test(arguments: [
		ToolName.intervalsFetchAthlete, .intervalsFetchWellness, .intervalsFetchActivity,
		.intervalsFetchStreams, .intervalsFetchActivities, .intervalsListEvents,
		.getPendingWorkoutChanges, .prepareWorkoutChanges, .memoryRead, .planSave,
	])
	func unconnectedCallToAnUnofferedToolReturnsUnknownToolAndReachesNoClient(name: ToolName)
		async throws
	{
		transport.respond = ScriptedReply.sequence(
			[
				.toolCall(
					name: name.rawValue,
					arguments:
						#"{"activityId":"i1234567","oldest":"1998-06-07","eventId":42,"date":"1998-06-14","name":"Core","description":"Floor work","workout":{"name":"Ride","steps":[{"type":"steady","duration":{"value":10,"unit":"minutes"}}]}}"#
				), .finish(reason: .toolCalls),
				.text("That is unavailable."), .finish(reason: .stop),
			], otherwise: transport.respond)
		let coach = await unconnectedCoach()

		let settled = try await coach.sendAndSettle("Read my training")

		#expect(replyText(settled) == "That is unavailable.")
		let result = try #require(transport.requests.last?.messages.last { $0.role == .tool })
		#expect(
			try JSONValue.parse(result.content)
				== .object([
					"error": .string("unknown_tool"),
					"details": .string(
						"This tool was not offered for this turn. Use an offered tool."),
				]))
		#expect(intervals.calls.isEmpty)
		for read in [FakeTrainingRead.profile, .wellness] {
			#expect(intervals.count(of: read) == 0)
		}
		#expect(
			try await store.fetch(RecordQuery(scope: .deviceLocal([.workoutReview]))).records
				.isEmpty)
	}

	@Test func unofferedToolCalledWithMalformedArgumentsReturnsUnknownTool() async throws {
		transport.respond = ScriptedReply.sequence(
			[
				.toolCall(name: "intervals_fetch_athlete", arguments: "{not json"),
				.finish(reason: .toolCalls),
				.text("That is unavailable."), .finish(reason: .stop),
			], otherwise: transport.respond)
		let coach = await unconnectedCoach()

		_ = try await coach.sendAndSettle("Read my training")

		let result = try #require(transport.requests.last?.messages.last { $0.role == .tool })
		#expect(
			try JSONValue.parse(result.content).objectFields["error"] == .string("unknown_tool"))
		#expect(intervals.calls.isEmpty)
	}

	@Test func repeatedReadInOneAttemptReachesTheClientOnceAndStaysEnveloped() async throws {
		intervals.wellness = [.on("1998-06-02", [.fitness: 51, .fatigue: 40])]
		let read = ScriptedEvent.toolCall(
			name: "intervals_fetch_wellness",
			arguments: #"{"oldest":"1998-06-01","newest":"1998-06-05"}"#)
		transport.respond = ScriptedReply.sequence(
			[
				read, read, .finish(reason: .toolCalls), read, .finish(reason: .toolCalls),
				.text("Read."), .finish(reason: .stop),
			], otherwise: transport.respond)
		let coach = await makeCoach(
			transport: transport, intervals: intervals, store: store, clock: clock)

		_ = try await coach.sendAndSettle("How was early June?")

		let results = try #require(transport.requests.last).messages
			.filter { $0.role == .tool }.map(\.content)
		#expect(results.count == 3)
		#expect(Set(results).count == 1)
		let envelope = try JSONValue.parse(try #require(results.first))
		#expect(envelope.objectFields["untrusted_data"] == .string(UntrustedEnvelope.banner))
		#expect(
			envelope.objectFields["data"]?.objectFields["days"]?.arrayValue?.first?
				.objectFields["fitness"] == .number(51))
		#expect(
			intervals.calls.filter { $0 == .wellness(oldest: "1998-06-01", newest: "1998-06-05") }
				.count == 1)
	}

	@Test func repeatedPlanningCallInOneAttemptRunsTheToolOnce() async throws {
		let draft = ScriptedEvent.toolCall(
			name: "build_plan_skeleton",
			arguments:
				#"{"experienceLevel":"intermediate","ftpWatts":250,"volumeTier":"medium","scheduleType":"flexible","goalType":"general"}"#
		)
		transport.respond = ScriptedReply.sequence(
			[
				draft, draft, .finish(reason: .toolCalls), draft, .finish(reason: .toolCalls),
				.text("Here is your plan."), .finish(reason: .stop),
			], otherwise: transport.respond)
		let coach = await makeCoach(
			transport: transport, intervals: intervals, store: store, clock: clock)

		_ = try await coach.sendAndSettle("Build me a plan")

		let results = try #require(transport.requests.last).messages
			.filter { $0.role == .tool }.map(\.content)
		#expect(results.count == 3)
		#expect(Set(results).count == 1)
		let first = try #require(results.first)
		let id = try JSONValue.parse(first).objectFields["data"]?.objectFields["id"]?.stringValue
		#expect(ULID(rawValue: try #require(id)) != nil)
	}

	@Test func memoryReadAfterAWriteInTheSameAttemptSeesTheWrite() async throws {
		let query = ScriptedEvent.toolCall(
			name: "memory_query", arguments: #"{"from":"1998-06-13","to":"1998-06-13"}"#)
		transport.respond = ScriptedReply.sequence(
			[
				query, .finish(reason: .toolCalls),
				.toolCall(
					name: "memory_write",
					arguments: #"{"type":"daily","content":"Knee felt sore on the climb."}"#),
				.finish(reason: .toolCalls),
				query, .finish(reason: .toolCalls),
				.text("Noted."), .finish(reason: .stop),
			], otherwise: transport.respond)
		let coach = await makeCoach(
			transport: transport, intervals: intervals, store: store, clock: clock)

		_ = try await coach.sendAndSettle("My knee was sore today")

		let results = try #require(transport.requests.last).messages
			.filter { $0.role == .tool }.map(\.content)
		try #require(results.count == 3)
		#expect(!results[0].contains("Knee felt sore on the climb."))
		#expect(results[2].contains("Knee felt sore on the climb."))
	}

	private func unconnectedCoach() async -> Coach {
		let secrets = ICloudKeychainStore(backing: FixtureSecretStoreBacking())
		do {
			try secrets.storeCreditsAccount(CreditsAccount(appAccountToken: UUID(), key: testKey))
		} catch {
			Issue.record(error)
		}
		return await makeCoach(
			transport: transport, intervals: intervals, store: store, clock: clock,
			secrets: secrets)
	}
}
