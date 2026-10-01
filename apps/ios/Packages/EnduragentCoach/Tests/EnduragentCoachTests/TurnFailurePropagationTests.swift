import EnduragentCoachFixtures
import Synchronization
import Testing

@testable import EnduragentCoach

@Suite struct TurnFailurePropagationTests {
	@Test func memoryContextReadFailureSettlesTheTurnWithoutARequest() async throws {
		try await expectPromptReadFailure(on: 1)
	}

	@Test func memoryViewReadFailureSettlesTheTurnWithoutARequest() async throws {
		try await expectPromptReadFailure(on: 2)
	}

	@Test func memorySectionValidationFailureDoesNotWrite() async throws {
		let store = InMemoryRecordLog()
		let failing = MemoryReadFailingLog(wrapping: store, failingOn: 3)
		let transport = FakeModelTransport()
		transport.respond = ScriptedReply.sequence(
			[
				.toolCall(
					name: "memory_write",
					arguments:
						#"{"type":"memory","section":"schedule","content":"Rides on Saturdays"}"#
				),
				.finish(reason: .toolCalls),
				.text("I could not save that."),
				.finish(reason: .stop),
			], otherwise: transport.respond)
		let coach = await makeCoach(transport: transport, store: failing)
		let settled = try await coach.sendAndSettle("Remember that I ride on Saturdays")
		#expect(replyText(settled) == "I could not save that.")
		#expect(transport.requests.count == 2)
		let followUp = try #require(transport.requests.dropFirst().first)
		let toolMessage = try #require(followUp.messages.last(where: { $0.role == .tool }))
		#expect(
			toolMessage.content
				== JSONValue.object([
					"error": .string("save_failed"),
					"details": .string("The change could not be saved on this device."),
				]).canonicalDigestInput())
		let failures = coach.diagnostics.entries.compactMap { entry -> ToolFault? in
			guard
				case .toolFailed(followUp.attempt, .memoryWrite, let failure) = entry.event
			else { return nil }
			return failure
		}
		#expect(failures == [.saveFailed])
		let memoryRecords = try await store.fetch(
			RecordQuery(scope: .synced([.memorySection, .provenance, .journal])))
		#expect(memoryRecords.records.isEmpty)
	}

	@Test(arguments: ["memory_read", "intervals_fetch_athlete"])
	func blankToolArgumentsRunTheParameterlessTool(name: String) async throws {
		var results: [String] = []
		for arguments in ["{}", ""] {
			let transport = FakeModelTransport()
			transport.respond = ScriptedReply.sequence(
				[
					.toolCall(name: name, arguments: arguments),
					.finish(reason: .toolCalls),
					.text("ok"),
					.finish(reason: .stop),
				], otherwise: transport.respond)
			let coach = await makeCoach(transport: transport, store: try await storeWithNotes())
			let settled = try await coach.sendAndSettle("Read my information")
			#expect(replyText(settled) == "ok")
			let followUp = try #require(transport.requests.dropFirst().first)
			let message = try #require(followUp.messages.last(where: { $0.role == .tool }))
			#expect(!message.content.contains("\"error\""))
			results.append(message.content)
		}
		#expect(results.first == results.last)
	}

	@Test(arguments: ["", "{}"])
	func blankToolArgumentsValidateRequiredParameters(arguments: String) async throws {
		let transport = FakeModelTransport()
		transport.respond = ScriptedReply.sequence(
			[
				.toolCall(name: "calculate_zones", arguments: arguments),
				.finish(reason: .toolCalls),
				.text("What is your FTP?"),
				.finish(reason: .stop),
			], otherwise: transport.respond)
		let coach = await makeCoach(transport: transport, store: InMemoryRecordLog())
		let settled = try await coach.sendAndSettle("Calculate my zones")
		#expect(replyText(settled) == "What is your FTP?")
		#expect(transport.requests.count == 2)
		let followUp = try #require(transport.requests.last)
		let message = try #require(followUp.messages.last(where: { $0.role == .tool }))
		let result = try JSONValue.parse(message.content)
		#expect(
			result.objectFields["data"]
				== .object([
					"error": .string("invalid_ftp"),
					"details": .string("ftpWatts is required."),
				]))
	}

	@Test(arguments: ["not-json", " ", "{", "undefined"])
	func invalidToolArgumentsReturnAToolError(arguments: String) async throws {
		let transport = FakeModelTransport()
		transport.respond = ScriptedReply.sequence(
			[
				.toolCall(name: "memory_read", arguments: arguments),
				.finish(reason: .toolCalls),
				.text("ok"),
				.finish(reason: .stop),
			], otherwise: transport.respond)
		let coach = await makeCoach(transport: transport, store: try await storeWithNotes())
		let settled = try await coach.sendAndSettle("read memory")
		#expect(replyText(settled) == "ok")
		#expect(transport.requests.count == 2)
		let followUp = try #require(transport.requests.dropFirst().first)
		let toolMessage = try #require(followUp.messages.last(where: { $0.role == .tool }))
		#expect(
			toolMessage.content
				== JSONValue.object([
					"error": .string("invalid_arguments"),
					"details": .string("Tool arguments were not valid JSON."),
				]).canonicalDigestInput())
	}

	private func storeWithNotes() async throws -> InMemoryRecordLog {
		let store = InMemoryRecordLog()
		let clock = FixedClock(now: "1998-06-13T08:00:00+02:00", timeZone: "Europe/Amsterdam")
		let memory = Memory(
			ledger: Ledger(log: store, clock: clock, diagnostics: DiagnosticsLog(clock: clock)),
			clock: clock)
		try await memory.writeSection(
			.notes, content: "Prefers hill repeats", source: .chat, stamp: testStamp())
		return store
	}

	private func expectPromptReadFailure(on occurrence: Int) async throws {
		let store = InMemoryRecordLog()
		let failing = MemoryReadFailingLog(wrapping: store, failingOn: occurrence)
		let transport = FakeModelTransport()
		transport.respond = ScriptedReply.sequence(
			[.text("This response must not be generated."), .finish(reason: .stop)], for: .chat,
			otherwise: transport.respond)
		let coach = await makeCoach(transport: transport, store: failing)
		let settled = try await coach.sendAndSettle("Plan my week")
		#expect(failure(settled) == .local(.recordStorage))
		#expect(transport.requests.isEmpty)
		#expect(await coach.transcript(.main) == ["Plan my week"])
		let turn = try #require(await coach.currentSnapshot(.main)?.turns.first?.id)
		let persisted = try await settlements(of: turn, in: store)
		#expect(persisted == [.failed(.local(.recordStorage), saved: .none)])
	}
}

private final class MemoryReadFailingLog: RecordLog, Sendable {
	let deviceId: DeviceID
	private let wrapped: any RecordLog
	private let failingOn: Int
	private let reads = Mutex(0)

	init(wrapping wrapped: any RecordLog, failingOn: Int) {
		self.deviceId = wrapped.deviceId
		self.wrapped = wrapped
		self.failingOn = failingOn
	}

	func append(_ batch: [AthleteRecord], locality: RecordLocality) async throws {
		try await wrapped.append(batch, locality: locality)
	}

	func latest(locality: RecordLocality, writtenBy: DeviceID) async throws -> RecordCursor? {
		try await wrapped.latest(locality: locality, writtenBy: writtenBy)
	}

	func fetch(_ query: RecordQuery) async throws -> RecordPage {
		if query.scope
			== .synced([.memorySection, .dailyNote, .ledgerEvent, .journal, .compactionSummary])
		{
			let occurrence = reads.withLock { count in
				count += 1
				return count
			}
			if occurrence == failingOn {
				throw RecordStorageFault(operation: .fetch)
			}
		}
		return try await wrapped.fetch(query)
	}

	var imports: AsyncStream<Void> {
		wrapped.imports
	}
}
