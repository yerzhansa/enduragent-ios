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
		transport.script = [
			.toolCall(
				name: "memory_write",
				arguments: #"{"type":"memory","section":"schedule","content":"Rides on Saturdays"}"#
			),
			.finish(reason: .toolCalls),
			.text("I could not save that."),
			.finish(reason: .stop),
		]
		let coach = makeCoach(transport: transport, store: failing)
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

	@Test func invalidToolArgumentsReturnAToolError() async throws {
		let transport = FakeModelTransport()
		transport.script = [
			.toolCall(name: "memory_read", arguments: "not-json"),
			.finish(reason: .toolCalls),
			.text("ok"),
			.finish(reason: .stop),
		]
		let coach = makeCoach(transport: transport, store: InMemoryRecordLog())
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

	private func expectPromptReadFailure(on occurrence: Int) async throws {
		let store = InMemoryRecordLog()
		let failing = MemoryReadFailingLog(wrapping: store, failingOn: occurrence)
		let transport = FakeModelTransport()
		transport.script = [.text("This response must not be generated."), .finish(reason: .stop)]
		let coach = makeCoach(transport: transport, store: failing)
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
