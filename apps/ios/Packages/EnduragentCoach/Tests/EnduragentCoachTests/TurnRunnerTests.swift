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
		var finished = false
		for try await event in coach.send("Keep fetching", chatId: "main") {
			if case .finished = event { finished = true }
		}
		#expect(finished)
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
		var text = ""
		for try await event in coach.send("Long history", chatId: "main") {
			if case .textDelta(let delta) = event { text += delta }
		}
		#expect(text.contains("after compact") || text.contains("truncated"))
		#expect(transport.requests.count >= 2)
		let records = try await store.fetch(
			RecordQuery(scope: .synced([.compactionSummary, .windowStart]), chatId: "main")
		).records
		#expect(!records.isEmpty)
	}

	@Test func backgroundRemainingBelowWatchdogInterruptsWithoutGenerate() async throws {
		clock.backgroundRemaining = .seconds(10)
		transport.script = [.text("should not run"), .finish(reason: .stop)]
		let coach = makeCoach()
		var interrupted: String?
		for try await event in coach.send("Any news?", chatId: "main") {
			if case .interrupted(let text) = event { interrupted = text }
		}
		#expect(interrupted != nil)
		#expect(transport.requests.isEmpty)
		let pending = try await store.fetch(
			RecordQuery(scope: .deviceLocal([.flushPending]), chatId: "main")
		).records
		#expect(!pending.isEmpty)
	}

	@Test func planSlashFinishesWithoutACard() async throws {
		transport.script = [.text("no"), .finish(reason: .stop)]
		let coach = makeCoach()
		var events: [CoachEvent] = []
		for try await event in coach.send("/plan", chatId: "main") {
			events.append(event)
		}
		#expect(events == [.finished])
		#expect(transport.requests.isEmpty)
		#expect(await coach.history(chatId: "main").isEmpty)
	}

	@Test func persistWritesUserMessageAndTurnSettledInOneBatch() async throws {
		transport.script = [.text("Noted."), .finish(reason: .stop)]
		let recording = BatchRecordingLog(inner: store)
		let coach = Coach(
			sport: .cycling,
			transport: transport,
			intervals: intervals,
			store: recording,
			clock: clock,
			language: .init(ui: .en, coachReply: nil)
		)
		for try await _ in coach.send("Remember Saturdays", chatId: "main") {}
		let persist = try #require(
			recording.batches.first { batch in batch.contains("userMessage") })
		#expect(persist == ["userMessage", "turnSettled"])
		let everyKind: [String] = recording.batches.flatMap { $0 }
		#expect(everyKind.filter { $0 == "turnSettled" }.count == 1)
		#expect(!everyKind.contains("assistantMessage"))
		let rows = try await store.fetch(
			RecordQuery(scope: .synced([.userMessage, .turnSettled]), chatId: "main")
		).records
		#expect(rows.count == 2)
		#expect(Set(rows.map(\.body.turn)).count == 1)
		#expect(rows.allSatisfy { $0.account == .unconnected })
		guard case .operation(.turn(let turn), let attempt)? = rows.first?.cause else {
			Issue.record("expected a turn stamp")
			return
		}
		#expect(rows.first?.body.turn == turn)
		#expect(rows.last?.cause == .operation(.turn(turn), attempt))
		#expect(
			await coach.history(chatId: "main").map(\.text) == ["Remember Saturdays", "Noted."])
	}

	private func makeCoach() -> Coach {
		Coach(
			sport: .cycling,
			transport: transport,
			intervals: intervals,
			store: store,
			clock: clock,
			language: .init(ui: .en, coachReply: nil)
		)
	}
}

private final class BatchRecordingLog: RecordLog, @unchecked Sendable {
	let inner: InMemoryRecordLog
	private(set) var batches: [[String]] = []

	init(inner: InMemoryRecordLog) {
		self.inner = inner
	}

	var deviceId: DeviceID { inner.deviceId }

	func append(_ batch: [AthleteRecord], locality: RecordLocality) async throws {
		batches.append(batch.map(\.body.kind))
		try await inner.append(batch, locality: locality)
	}

	func fetch(_ query: RecordQuery) async throws -> RecordPage {
		try await inner.fetch(query)
	}

	var imports: AsyncStream<Void> { inner.imports }
}
