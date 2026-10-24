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
				.memoryQuery, .memoryWrite, .ledgerAppend, .planSave, .planLoad,
			])
		#expect(
			offered.last == [
				.calculateZones, .buildPlanSkeleton, .assessFeasibility, .getSampleWeek,
				.memoryRead, .memoryQuery, .memoryWrite, .ledgerAppend, .planSave, .planLoad,
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
				.ledgerAppend, .planSave, .planLoad,
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

		#expect(defined.map(\.name) == ToolName.allCases)
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
		.getPendingWorkoutChanges, .prepareWorkoutChanges, .memoryRead,
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

	@Test func planLoadIsMemoizedUntilAMemoryWriteAndReturnsTheNewestSavedPlanWhole()
		async throws
	{
		let base: JSONValue = .object([
			"name": .string("Base"), "totalWeeks": .number(8),
			"phases": .array([.object(["number": .number(1), "focus": .string("base_building")])]),
		])
		let build: JSONValue = .object([
			"name": .string("Build"), "primaryGoal": .string("century"),
			"status": .string("active"),
			"phases": .array([
				.object(["number": .number(1), "focus": .string("aerobic_development")]),
				.object(["number": .number(2), "focus": .string("taper"), "weeks": .array([])]),
			]),
			"extra": .object(["nested": .array([.number(1), .bool(true), .null])]),
		])
		let ledger = Ledger(log: store, clock: clock, diagnostics: DiagnosticsLog(clock: clock))
		let offered = makeOfferedTools(intervals: intervals, ledger: ledger, clock: clock)
		let scope = TurnScope(stamp: testStamp(), policy: .npm, ladder: .npm, uptime: .zero)
		let phone = store.deviceId
		try await seed(
			store,
			[
				storedRecord(
					device: phone, wall: 10, ulid: fixedUlid(10),
					body: try SavedPlanRows.body(
						base, id: 1, confirmation: 2,
						decided: HybridLogicalClock(wallMs: 5, logical: 0, deviceId: phone)))
			])

		let first = try await planLoad(offered, scope)
		try await seed(
			store,
			[
				storedRecord(
					device: phone, wall: 20, ulid: fixedUlid(20),
					body: try SavedPlanRows.body(
						build, id: 3, confirmation: 4,
						decided: HybridLogicalClock(wallMs: 8, logical: 0, deviceId: phone)))
			])
		let memoized = try await planLoad(offered, scope)
		_ = try await offered.execute(
			name: .memoryWrite,
			arguments: .object(["type": .string("daily"), "content": .string("Legs felt fresh.")]),
			scope: scope)
		let afterWrite = try await planLoad(offered, scope)

		#expect(first == base)
		#expect(memoized == base)
		#expect(afterWrite == build)
		#expect(
			try await planLoad(
				offered, TurnScope(stamp: testStamp(), policy: .npm, ladder: .npm, uptime: .zero))
				== build)
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

	private func planLoad(_ offered: OfferedTools, _ scope: TurnScope) async throws -> JSONValue {
		let execution = try await offered.execute(
			name: .planLoad, arguments: .object([:]), scope: scope)
		guard case .result(let envelope) = execution.outcome else {
			throw PlanFixtureFailure(description: "plan_load answered \(execution.outcome)")
		}
		#expect(envelope.objectFields["untrusted_data"] == .string(UntrustedEnvelope.banner))
		return try #require(envelope.objectFields["data"])
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
