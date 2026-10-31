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
				credential: ProviderCredential(secret: key, method: .credits), model: testModel,
				provider: .fixtureHost),
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

	@Test func aRecordedLineSurvivesANewLog() throws {
		let directory = try Self.folder()
		let file = directory.appending(path: "diagnostics.jsonl")
		let log = DiagnosticsLog(clock: clock, storage: FileJournalStorage(directory: directory))
		let event = DiagnosticsEvent.memoryFlushFailed(.main, .cocoa(4))
		log.record(event)
		let problem = StampedLine(at: clock.now, line: .problem(event.line))
		#expect(try Self.lines(in: Data(contentsOf: file)) == [problem])
		let usage = try Self.usage(cost: .reported(0.0042))
		log.recordUsage(usage)
		let used = StampedLine(at: clock.now, line: .usage(usage))
		#expect(try Self.lines(in: Data(contentsOf: file)) == [problem, used])
		let reopened = DiagnosticsLog(
			clock: clock, storage: FileJournalStorage(directory: directory))
		#expect(reopened.window(endingAt: clock.now) == [problem, used])
	}

	@Test func aTornFileIsRecordedAsADroppedLine() throws {
		let directory = try Self.folder()
		let file = directory.appending(path: "diagnostics.jsonl")
		let whole = StampedLine(
			at: clock.now, line: .problem(DiagnosticsEvent.recoveryUnavailable(.unavailable).line))
		let torn = try whole.encoded()
		try (torn + Data("\n".utf8) + torn.prefix(torn.count / 2)).write(to: file)
		let log = DiagnosticsLog(clock: clock, storage: FileJournalStorage(directory: directory))
		let dropped = DiagnosticsEvent.journalLinesDropped(count: 1)
		#expect(log.entries.map(\.event) == [dropped])
		#expect(
			try Self.lines(in: Data(contentsOf: file)) == [
				whole, StampedLine(at: clock.now, line: .problem(dropped.line)),
			])
	}

	@Test func anUnreadableFileIsRecordedAsARestart() throws {
		let storage = MemoryJournalStorage()
		storage.failReads()
		let log = DiagnosticsLog(clock: clock, storage: storage)
		let restarted = DiagnosticsEvent.journalRestarted(.unreadable)
		#expect(log.entries.map(\.event) == [restarted])
		#expect(
			try Self.lines(in: #require(storage.contents)) == [
				StampedLine(at: clock.now, line: .problem(restarted.line))
			])
	}

	@Test func entriesHoldEveryEventOfThisProcessAndNothingElse() throws {
		let directory = try Self.folder()
		let first = DiagnosticsLog(clock: clock, storage: FileJournalStorage(directory: directory))
		let events = (0..<201).map { DiagnosticsEvent.memoryFlushFailed(.main, .cocoa($0)) }
		for event in events {
			first.record(event)
		}
		first.recordUsage(try Self.usage(cost: .unreported))
		#expect(first.entries.map(\.event) == events)
		let second = DiagnosticsLog(clock: clock, storage: FileJournalStorage(directory: directory))
		#expect(second.entries.isEmpty)
		second.record(.preferencesUnavailable(.unavailable))
		#expect(second.entries.map(\.event) == [.preferencesUnavailable(.unavailable)])
		#expect(second.window(endingAt: clock.now).count == 203)
	}

	@Test func aLedgerReportsTheFirstHundredSkippedRows() async throws {
		let diagnostics = DiagnosticsLog(clock: clock)
		let rows = (0..<101).map { SkippedRow.malformed(kind: "userMessage", ulid: "row-\($0)") }
		let ledger = Ledger(
			log: UnreadableLog(rows: rows), chain: InMemoryRecordLog(), clock: clock,
			diagnostics: diagnostics)
		_ = try await ledger.read(RecordQuery(scope: .everySynced))
		_ = try await ledger.read(RecordQuery(scope: .everySynced))
		#expect(
			diagnostics.entries.map(\.event)
				== rows.prefix(100).map { DiagnosticsEvent.skippedRecord($0) })
	}

	@Test func aSkippedRowIsWrittenScrubbed() throws {
		let directory = try Self.folder()
		let log = DiagnosticsLog(clock: clock, storage: FileJournalStorage(directory: directory))
		let url = "https://x.test/?k=sk-or-v1-abc"
		let token = "gh" + "p_" + String(repeating: "a1", count: 18)
		log.record(.skippedRecord(.malformed(kind: url, ulid: token)))
		let written = String(
			decoding: try Data(contentsOf: directory.appending(path: "diagnostics.jsonl")),
			as: UTF8.self)
		for text in ["sk-or-v1-abc", token, "x.test", url] {
			#expect(!written.contains(text))
		}
		#expect(written.contains("[redacted]"))
	}

	@Test func aLineThatCannotBeEncodedStopsSavingUntilTheNextWrite() throws {
		let storage = MemoryJournalStorage()
		let log = DiagnosticsLog(clock: clock, storage: storage)
		log.recordUsage(try Self.usage(cost: .reported(.nan)))
		#expect(log.health == .notSaving(since: clock.now, firstCause: .appendFailed))
		#expect(storage.contents == nil)
		let event = DiagnosticsEvent.recoveryUnavailable(.unavailable)
		log.record(event)
		#expect(log.health == .saving)
		#expect(
			try Self.lines(in: #require(storage.contents)) == [
				StampedLine(at: clock.now, line: .problem(event.line))
			])
	}

	private static func folder() throws -> URL {
		let directory = try TestTemporaryFolders.make()
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		return directory
	}

	private static func lines(in data: Data) throws -> [StampedLine] {
		try #require(data.last == UInt8(ascii: "\n"))
		return try data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
			.dropLast().map { try StampedLine(decoding: Data($0)) }
	}

	private static func usage(cost: UsageCost) throws -> UsageLine {
		UsageLine(
			origin: .turn(turn: fixedUlid(21), attempt: fixedUlid(22), ending: .replied),
			model: try #require(ModelRef(testModel)), calls: 2, failedCalls: 0,
			inputTokens: 1_200, outputTokens: 300, cost: cost, durationMilliseconds: 1_500)
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
