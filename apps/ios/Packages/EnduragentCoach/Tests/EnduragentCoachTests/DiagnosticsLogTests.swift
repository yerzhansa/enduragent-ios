import Foundation
import Testing

@testable import EnduragentCoach

@Suite struct DiagnosticsLogTests {
	let clock = FixedClock(now: "1998-06-13T08:00:00+02:00", timeZone: "Europe/Amsterdam")

	@Test func rawBodyIsStoredRedactedAndBounded() async throws {
		let diagnostics = DiagnosticsLog(clock: clock)
		let otherKey = "sk-or-v1-0123456789abcdef"
		let body = """
			{"error":{"message":"User not found.","code":401,"metadata":{"echo":"Authorization: Bearer \(testKey)","seen":"\(otherKey)"}}}
			"""
		let transport = try OpenRouterStub.transport(diagnostics: diagnostics) { _ in
			.reply(.json(401, body))
		}
		let attempt = AttemptID(ulid: fixedUlid(41))
		await #expect(throws: ProviderFailure.credentialRejected(status: 401)) {
			_ = try await collect(
				transport.stream(
					testRequest(
						[WireMessage(role: .user, content: "Hi", toolCalls: [], toolCallId: nil)],
						attempt: attempt)))
		}
		let entry = try #require(diagnostics.entries.only)
		let event = entry.event
		guard case .providerFailure(attempt, .credentialRejected(status: 401), let detail) = event
		else {
			Issue.record("expected the 401 keyed by its attempt, got \(event)")
			return
		}
		#expect(detail.contains("User not found."))
		#expect(!detail.contains(testKey))
		#expect(!detail.contains(otherKey))
		#expect(detail.contains("[redacted]"))
		#expect(entry.at == clock.now)

		diagnostics.record(
			.providerFailure(
				attempt, .serverError(status: 500, retryAfter: nil),
				detail: String(repeating: "x", count: 10_000)))
		#expect(diagnostics.entries.last.map(detailLength) == DiagnosticsLog.detailLimit)

		for index in 0..<(DiagnosticsLog.capacity + 50) {
			diagnostics.record(.memoryFlushFailed(.main, detail: "flush \(index)"))
		}
		let kept = diagnostics.entries
		#expect(kept.count == DiagnosticsLog.capacity)
		#expect(kept.first?.event == .memoryFlushFailed(.main, detail: "flush 50"))
		#expect(kept.last?.event == .memoryFlushFailed(.main, detail: "flush 249"))
	}

	@Test func requestKeyIsRedactedEvenWithoutAKnownPrefix() async throws {
		let diagnostics = DiagnosticsLog(clock: clock)
		let key = "fixture-credits-key"
		let transport = try OpenRouterStub.transport(diagnostics: diagnostics) { _ in
			.reply(.json(401, #"{"error":{"message":"Key \#(key) is not valid."}}"#))
		}
		let access = ResolvedAccess(
			credential: ProviderCredential(secret: key, method: .credits), model: testModel)
		let request = CompletionRequest(
			access: access, attempt: AttemptID(ulid: fixedUlid(42)), charge: .chatAttempt,
			messages: [WireMessage(role: .user, content: "Hi", toolCalls: [], toolCallId: nil)],
			tools: [], deadline: .seconds(30))
		await #expect(throws: ProviderFailure.credentialRejected(status: 401)) {
			_ = try await collect(transport.stream(request))
		}
		let entry = try #require(diagnostics.entries.only)
		guard case .providerFailure(_, _, let detail) = entry.event else {
			Issue.record("expected a provider failure, got \(entry.event)")
			return
		}
		#expect(!detail.contains(key))
		#expect(detail.contains("Key [redacted] is not valid."))
	}

	@Test func unreadableRowsCannotFlushProviderFailuresOutOfTheRing() async throws {
		let diagnostics = DiagnosticsLog(clock: clock)
		let failure = DiagnosticsEvent.providerFailure(
			AttemptID(ulid: fixedUlid(43)), .network, detail: "URLError -1009")
		diagnostics.record(failure)
		let rows = (0..<250).map { SkippedRow.malformed(kind: "userMessage", ulid: "row-\($0)") }
		let ledger = Ledger(log: UnreadableLog(rows: rows), clock: clock, diagnostics: diagnostics)
		_ = try await ledger.read(RecordQuery(scope: .everySynced))
		_ = try await ledger.read(RecordQuery(scope: .everySynced))
		let events = diagnostics.entries.map(\.event)
		#expect(events.first == failure)
		#expect(events.count == 1 + Ledger.reportedSkipLimit)
		let skipped = events.compactMap { event -> SkippedRow? in
			guard case .skippedRecord(let row) = event else { return nil }
			return row
		}
		#expect(Set(skipped).count == Ledger.reportedSkipLimit)
	}

	@Test(arguments: [true, false])
	func softFlushFailureIsRecordedNotDropped(keyStored: Bool) async throws {
		let transport = FakeModelTransport()
		transport.script = [.text("Noted."), .finish(reason: .stop)]
		let secrets = keyedSecrets()
		let coach = makeCoach(
			transport: transport, store: InMemoryRecordLog(), clock: clock, secrets: secrets)
		_ = try await coach.sendAndSettle("Remember that I ride on Saturdays")
		transport.failures = [.http(status: 500)]
		if !keyStored {
			secrets.locked = true
		}
		await coach.waitForMemoryFlush()
		let flushFailures = coach.diagnostics.entries.compactMap { entry -> String? in
			guard case .memoryFlushFailed(.main, let detail) = entry.event else { return nil }
			return detail
		}
		let expected = keyStored ? "serverError" : "secureStorageLocked"
		#expect(flushFailures.count == 1)
		#expect(flushFailures.first?.contains(expected) == true)
		#expect(transport.requestCount == (keyStored ? 2 : 1))
	}
}

extension SwiftDataSuites {
	@Suite struct SkippedRowDiagnosticsTests {
		let clock = FixedClock(now: "1998-06-13T08:00:00+02:00", timeZone: "Europe/Amsterdam")

		@Test func skippedV1RowIsRecordedOnceAndLeavesTheTranscript() async throws {
			let store = try V1Store.materialize()
			let log = try store.open(deviceId: DeviceID(rawValue: "phone-a"))
			try store.insertRaw(
				kind: "userMessage", bodyVersion: 1, ulid: "01MALFRMD00000000000000000")
			let transport = FakeModelTransport()
			transport.script = [.text("Noted."), .finish(reason: .stop)]
			let coach = makeCoach(transport: transport, store: log, clock: clock)
			let before = await coach.transcript(.main)
			_ = try await coach.sendAndSettle("Still on for Saturday?")
			let after = await coach.transcript(.main)
			#expect(after == before + ["Still on for Saturday?", "Noted."])
			#expect(
				coach.diagnostics.entries.map(\.event) == [
					.skippedRecord(
						.malformed(kind: "userMessage", ulid: "01MALFRMD00000000000000000"))
				])
		}
	}
}

private struct UnreadableLog: RecordLog {
	let deviceId = DeviceID(rawValue: "phone-a")
	let rows: [SkippedRow]

	func append(_ batch: [AthleteRecord], locality: RecordLocality) async throws {}

	func fetch(_ query: RecordQuery) async throws -> RecordPage {
		RecordPage(records: [], skipped: rows)
	}

	var imports: AsyncStream<Void> {
		AsyncStream { _ in }
	}
}

private func detailLength(_ entry: DiagnosticsEntry) -> Int? {
	switch entry.event {
	case .providerFailure(_, _, let detail), .toolFailed(_, _, let detail),
		.memoryFlushFailed(_, let detail):
		return detail.count
	case .skippedRecord:
		return nil
	}
}

extension Array {
	fileprivate var only: Element? {
		count == 1 ? first : nil
	}
}
