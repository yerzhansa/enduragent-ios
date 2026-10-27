import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

@Suite struct DiagnosticsLogTests {
	let clock = FixedClock(now: "1998-06-13T08:00:00+02:00", timeZone: "Europe/Amsterdam")

	@Test func providerBodyLeavesOnlyItsStatusAndCodeInTheLog() async throws {
		let diagnostics = DiagnosticsLog(clock: clock)
		let key = "fixture-credits-key"
		let otherKey = "sk-or-v1-0123456789abcdef"
		let athleteText = "My left knee aches after Saturday's long ride"
		let body = """
			{"error":{"message":"Key \(key) refused: \(athleteText)","code":401,"metadata":{"echo":"Authorization: Bearer \(testKey)","seen":"\(otherKey)"}}}
			"""
		let transport = try OpenRouterStub.transport(diagnostics: diagnostics) { _ in
			.reply(.json(401, body))
		}
		let attempt = AttemptID(ulid: fixedUlid(41))
		let request = CompletionRequest(
			access: ResolvedAccess(
				credential: ProviderCredential(secret: key, method: .credits), model: testModel),
			attempt: attempt, charge: .chatAttempt,
			messages: [
				WireMessage(role: .user, content: athleteText, toolCalls: [], toolCallId: nil)
			],
			tools: [], deadline: .seconds(30))
		await #expect(throws: ProviderFailure.credentialRejected(status: 401)) {
			_ = try await collect(transport.stream(request))
		}
		let entry = try #require(diagnostics.entries.only)
		#expect(
			entry.event
				== .providerFailure(
					attempt, .credentialRejected(status: 401),
					detail: .http(status: 401, openRouter: .code(401))))
		#expect(entry.at == clock.now)
		let logged = String(describing: diagnostics.entries)
		for text in [athleteText, "knee", key, testKey, otherKey] {
			#expect(!logged.contains(text))
		}
	}

	@Test func ringKeepsTheNewestEntries() {
		let diagnostics = DiagnosticsLog(clock: clock)
		for index in 0..<(DiagnosticsLog.capacity + 50) {
			diagnostics.record(.memoryFlushFailed(.main, .cocoa(index)))
		}
		let kept = diagnostics.entries
		#expect(kept.count == DiagnosticsLog.capacity)
		#expect(kept.first?.event == .memoryFlushFailed(.main, .cocoa(50)))
		#expect(kept.last?.event == .memoryFlushFailed(.main, .cocoa(249)))
	}

	@Test func unreadableRowsCannotFlushProviderFailuresOutOfTheRing() async throws {
		let diagnostics = DiagnosticsLog(clock: clock)
		let failure = DiagnosticsEvent.providerFailure(
			AttemptID(ulid: fixedUlid(43)), .network, detail: .url(-1009))
		diagnostics.record(failure)
		let rows = (0..<250).map { SkippedRow.malformed(kind: "userMessage", ulid: "row-\($0)") }
		let ledger = Ledger(
			log: UnreadableLog(rows: rows), chain: InMemoryRecordLog(), clock: clock,
			diagnostics: diagnostics)
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
	func flushFailureIsRecordedNotDropped(keyStored: Bool) async throws {
		let store = InMemoryRecordLog()
		let history = try await seedHistory(store, clock: clock, turns: 1, tokens: 200)
		let at = clock.now.addingTimeInterval(-5)
		try await seed(
			store,
			[
				seededRecord(
					store, at: at, ulid: ULID.generate(at: at),
					body: .deviceLocal(
						.flushPending(
							FlushPendingBody(
								chatId: .main, messageUlids: [history[0].user, history[0].reply]))))
			])
		let transport = FakeModelTransport()
		transport.respond = ScriptedReply.sequence(
			Array(repeating: .fail(.http(status: 500)), count: 3), for: .flush,
			otherwise: transport.respond)
		let backing = FixtureSecretStoreBacking()
		let secrets = keyedSecrets(backing: backing)
		backing.locked = !keyStored
		let coach = await makeCoach(
			transport: transport, store: store, clock: clock, secrets: secrets)
		await coach.lifecycle(.becameActive)
		let deadline = ContinuousClock.now + TestWaitLimit.hangGuard.duration
		var flushFailures: [FailureCode] = []
		while flushFailures.isEmpty, ContinuousClock.now < deadline {
			try await Task.sleep(for: .milliseconds(10))
			flushFailures = coach.diagnostics.entries.compactMap { entry -> FailureCode? in
				guard case .memoryFlushFailed(.main, let code) = entry.event else { return nil }
				return code
			}
		}
		let expected: FailureCode =
			keyStored
			? .flush(.failed(.model(.providerDown(.outage)))) : .access(.secureStorageLocked)
		#expect(flushFailures == [expected])
		#expect(transport.requestCount == (keyStored ? 3 : 0))
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
			transport.respond = ScriptedReply.sequence(
				[.text("Noted."), .finish(reason: .stop)], otherwise: transport.respond)
			let coach = await makeCoach(transport: transport, store: log, clock: clock)
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

	func latest(locality: RecordLocality, writtenBy: DeviceID) async throws -> RecordCursor? {
		nil
	}

	func fetch(_ query: RecordQuery) async throws -> RecordPage {
		RecordPage(records: [], skipped: rows)
	}

	var imports: AsyncStream<Void> {
		AsyncStream { _ in }
	}
}

extension Array {
	fileprivate var only: Element? {
		count == 1 ? first : nil
	}
}
