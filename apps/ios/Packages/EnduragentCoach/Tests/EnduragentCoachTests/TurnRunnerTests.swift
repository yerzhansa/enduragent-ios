import Foundation
import Testing

@testable import EnduragentCoach

@Suite struct TurnRunnerTests {
	let transport = FakeModelTransport()
	let intervals = FakeIntervalsClient(athleteName: "Ada", ftp: 250)
	let store = InMemoryRecordLog()
	let clock = FixedClock(now: "1998-06-13T08:00:00+02:00", timeZone: "Europe/Amsterdam")

	@Test func tenthStepRunsToolsThenStops() async throws {
		intervals.activities = [
			.ride(name: "Sunday long ride", date: "1998-06-07", durationS: 7200, trainingLoad: 120)
		]
		var script: [ScriptedEvent] = []
		for _ in 0..<10 {
			script.append(.text("."))
			script.append(.toolCall(name: "intervals_fetch_activities", arguments: #"{"days":7}"#))
			script.append(.finish(reason: .toolCalls))
		}
		transport.script = script
		let coach = makeCoach()
		let settled = try await coach.sendAndSettle("Keep fetching")
		#expect(replyText(settled) == ".")
		#expect(transport.requests.count == 10)
	}

	@Test func overflowLengthCompactsAndRetries() async throws {
		transport.finishUsage = Usage(
			inputTokens: TurnPolicy.contextWindowCap, outputTokens: 8, cost: nil)
		transport.script = [
			.text("truncated"),
			.finish(reason: .length),
			.text(
				"## Athlete Profile\n## Training Status\n## Coach Stance\n## Discussion Context\n## Pending Questions"
			),
			.finish(reason: .stop),
			.text("after compact"),
			.finish(reason: .stop),
		]
		let coach = makeCoach()
		let settled = try await coach.sendAndSettle("Long history")
		let text = try #require(replyText(settled))
		#expect(text.contains("after compact") || text.contains("truncated"))
		#expect(transport.requests.count >= 2)
		let records = try await store.fetch(
			RecordQuery(scope: .synced([.compactionSummary, .windowStart]), chatId: "main")
		).records
		#expect(!records.isEmpty)
	}

	@Test func lifecycleRecordsAreWrittenInThreeBatchesAroundTheModelCall() async throws {
		transport.script = [.text("Noted."), .finish(reason: .stop)]
		let recording = BatchRecordingLog(inner: store)
		let coach = EnduragentCoachTests.makeCoach(
			transport: transport, intervals: intervals, store: recording, clock: clock)
		let turn = try #require(
			try await coach.send(draft("Remember Saturdays"), to: .main).acceptedTurn)
		_ = try #require(await coach.settledState(of: turn, in: .main))
		#expect(recording.batches == [["userMessage"], ["turnClaim"], ["turnSettled"]])
		let everyKind: [String] = recording.batches.flatMap { $0 }
		#expect(!everyKind.contains("assistantMessage"))
		let synced = try await store.fetch(
			RecordQuery(scope: .synced([.userMessage, .turnSettled]), chatId: "main")
		).records
		let local = try await store.fetch(
			RecordQuery(scope: .deviceLocal([.turnClaim]), chatId: "main")
		)
		.records
		#expect(synced.map(\.body.kind) == ["userMessage", "turnSettled"])
		#expect(local.map(\.body.kind) == ["turnClaim"])
		#expect(Set((synced + local).map(\.body.turn)) == [turn])
		#expect((synced + local).allSatisfy { $0.account == .unconnected })
		guard case .operation(.turn(let claimedTurn), let attempt)? = local.first?.cause else {
			Issue.record("expected a turn stamp on the claim")
			return
		}
		#expect(claimedTurn == turn)
		#expect(synced.last?.cause == .operation(.turn(turn), attempt))
		guard case .operation(.turn(let acceptedTurn), let acceptAttempt)? = synced.first?.cause
		else {
			Issue.record("expected a turn stamp on the accept")
			return
		}
		#expect(acceptedTurn == turn)
		#expect(acceptAttempt != attempt)
		#expect(await coach.transcript(.main) == ["Remember Saturdays", "Noted."])
	}

	@Test func toolErrorReturnsToTheModelAsAResult() async throws {
		intervals.loadFailure = IntervalsError(
			code: "down", details: "intervals.icu is unavailable.")
		transport.script = [
			.toolCall(name: "intervals_fetch_wellness", arguments: #"{"days":7}"#),
			.finish(reason: .toolCalls),
			.text("I could not read your wellness data."),
			.finish(reason: .stop),
		]
		let coach = makeCoach()
		let settled = try await coach.sendAndSettle("How am I recovering?")
		#expect(replyText(settled) == "I could not read your wellness data.")
		#expect(transport.requests.count == 2)
		let toolMessage = try #require(
			transport.requests[1].messages.last(where: { $0.role == .tool }))
		#expect(toolMessage.content.contains("intervals.icu is unavailable."))
	}

	@Test func providerErrorsSettleAsTypedFailures() async throws {
		transport.failures = [URLError(.notConnectedToInternet)]
		let coach = makeCoach()
		let network = try await coach.sendAndSettle("one")
		#expect(failure(network) == .model(.providerDown(.network)))
		transport.failures = [UnknownFinishReasonError(reason: "weird")]
		let finish = try await coach.sendAndSettle("two")
		#expect(failure(finish) == .model(.generationFailed(.unknownFinish)))
		#expect(await coach.transcript(.main) == ["one", "two"])
		let prompt = try #require(transport.requests.last)
		#expect(prompt.messages.filter { $0.role == .user }.count == 1)
	}

	private func makeCoach() -> Coach {
		EnduragentCoachTests.makeCoach(
			transport: transport, intervals: intervals, store: store, clock: clock)
	}
}
