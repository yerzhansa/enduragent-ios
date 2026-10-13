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
		#expect(offered.first == [.calculateZones, .memoryQuery, .memoryWrite, .ledgerAppend])
		#expect(
			offered.last == [
				.calculateZones, .memoryRead, .memoryQuery, .memoryWrite, .ledgerAppend,
			])
	}

	@Test func connectedTurnCarriesTheToolListAsItWasBeforeTheToolTable() async throws {
		transport.respond = ScriptedReply.sequence(
			[.text("Easy spin today."), .finish(reason: .stop)], otherwise: transport.respond)
		let coach = await makeCoach(
			transport: transport, intervals: intervals, store: store, clock: clock)

		_ = try await coach.sendAndSettle("What should I ride?")

		let request = try #require(transport.requests.first)
		#expect(wire(request.tools) == (try pinned("connected")))
	}

	@Test func connectedOfferWithHiddenMemoryAndAnOrphanSectionIsUnchanged() throws {
		let offer = makeToolOffer(
			training: connectedTraining(intervals),
			ledger: Ledger(log: store, clock: clock, diagnostics: DiagnosticsLog(clock: clock)),
			clock: clock,
			memory: MemoryView(
				sections: ["notes": "stamp\n- Prefers hill repeats"], todayNotes: nil,
				planHeadline: nil, orphanNames: ["random-legacy"]))

		#expect(
			wire(offer.schemas) == (try pinned("connectedWithHiddenMemoryAndOrphanSection")))
	}

	@Test func unconnectedPromptSaysTrainingDataIsNotConnected() async throws {
		transport.respond = ScriptedReply.sequence(
			[.text("Easy spin today."), .finish(reason: .stop)], otherwise: transport.respond)
		let coach = await unconnectedCoach()

		_ = try await coach.sendAndSettle("How is my form?")

		let system = try #require(transport.requests.first?.messages.first?.content)
		#expect(
			system.contains(
				"""
				# Athlete Profile & Latest Wellness

				Training data is not connected. No intervals.icu account is linked, so you have \
				no profile, wellness, activities or calendar for this athlete and no tools to \
				read them. When the athlete asks for something that needs that data, say so, \
				tell them they can connect intervals.icu in Settings, and do not invent numbers.

				---
				"""))
		#expect(!system.contains("fetch the profile and latest wellness before prescribing"))
	}

	@Test(arguments: [
		ToolName.intervalsFetchAthlete, .intervalsFetchWellness, .intervalsFetchActivity,
		.intervalsFetchStreams, .intervalsFetchActivities, .intervalsListEvents,
		.intervalsCreateWorkout, .intervalsCreateStrengthWorkout, .intervalsDeleteWorkout,
		.intervalsUpdateWorkout, .memoryRead, .planSave,
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
			try await store.fetch(RecordQuery(scope: .deviceLocal([.pendingProposal]))).records
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
			envelope.objectFields["data"]?.arrayValue?.first?.objectFields["fitness"]
				== .number(51))
		#expect(
			intervals.calls.filter { $0 == .wellness(oldest: "1998-06-01", newest: "1998-06-05") }
				.count == 1)
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

	private func wire(_ schemas: [ToolSchema]) -> String {
		JSONValue.array(
			schemas.map {
				.object([
					"name": .string($0.name.rawValue),
					"description": .string($0.description),
					"parameters": $0.parameters,
				])
			}
		).canonicalDigestInput()
	}

	private func pinned(_ list: String) throws -> String {
		let fixture = try JSONValue.parse(
			try #require(String(data: try fixtureData("tool-list-before-table"), encoding: .utf8)))
		return try #require(fixture.objectFields[list]).canonicalDigestInput()
	}
}
