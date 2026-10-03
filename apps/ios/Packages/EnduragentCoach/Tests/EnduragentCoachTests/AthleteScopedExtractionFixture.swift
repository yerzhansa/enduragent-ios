import EnduragentCoachFixtures
import Foundation
import Synchronization
import Testing

@testable import EnduragentCoach

struct AthleteScopedExtractionFixture {
	let base: AthleteScopedCoachingFixture

	init(store: any RecordLog = InMemoryRecordLog()) throws {
		base = try AthleteScopedCoachingFixture(store: store)
	}

	func open(store: (any RecordLog)? = nil, transport: (any ModelTransport)? = nil) async -> Coach
	{
		var ports = CoachPorts(
			records: RecordStore(log: store ?? base.store), secrets: base.secrets,
			models: ModelService { _ in transport ?? base.transport },
			training: .fake { credential, _ in base.peer.client(for: credential) },
			credits: .fake(FakeCreditsClient()), host: ImmediateExecutionHost(), clock: base.clock)
		ports.watchdogSleep = HeldClock().sleep
		return await consentingCoach(
			Coach(
				sport: .cycling, ports: ports, builtInModel: testModel,
				displayLocale: testDisplayLocale, coalescing: quickWindow))
	}

	@discardableResult
	func seedRows(_ label: String, account: TrainingAccount, start: Int, tokens: Int = 40)
		async throws -> [AthleteRecord]
	{
		let turn = TurnID(ulid: fixedUlid(start))
		let rows = [
			base.record(
				start, account: account,
				body: .synced(sampleUser(chatId: .main, text: "\(label)_QUESTION", turn: turn))),
			base.record(
				start + 1, account: account,
				body: .synced(
					sampleReply(
						chatId: .main, turn: turn,
						text: "\(label)_REPLY " + String(repeating: "w", count: tokens * 4)))),
		]
		try await seed(base.store, rows)
		return rows
	}

	func extract(_ label: String) -> ScriptedReply {
		ScriptedReply([
			.toolCall(
				name: "memory_write",
				arguments: "{\"section\":\"person\",\"content\":\"\(label)_EXTRACTED\"}"),
			.toolCall(
				name: "ledger_append",
				arguments: #"{"kind":"decision","date":"1998-06-13","text":"SHARED_EVENT"}"#),
			.finish(reason: .toolCalls),
		])
	}

	func scriptExtraction() {
		base.transport.respond = { request in
			guard request.purpose == .flush else {
				return ScriptedReply([.text("Reply saved."), .finish(reason: .stop)])
			}
			guard request.step == 0 else { return ScriptedReply([.finish(reason: .stop)]) }
			return extract(request.userMessages.contains { $0.contains("B_SOURCE") } ? "B" : "A")
		}
	}

	func assertMemory(
		_ label: String, excluding other: String, account: TrainingAccount, coach: Coach
	) async throws {
		let context = try await coach.memory.fullContext(for: account)
		#expect(context.contains("\(label)_EXTRACTED"))
		#expect(!context.contains("\(other)_EXTRACTED"))
		#expect(context.contains("SHARED_EVENT"))
	}

	func jobs(in store: (any RecordLog)? = nil) async throws -> [FlushJob] {
		let ledger = Ledger(
			log: store ?? base.store, clock: base.clock,
			diagnostics: DiagnosticsLog(clock: base.clock))
		return try await ledger.flushJobs(in: try await ledger.conversation(.main))
	}
}

final class HeldExtractionTransport: ModelTransport {
	private let inner: FakeModelTransport
	private let first = Mutex(true)
	private let held = Mutex(false)
	private let gate = Gate()

	init(_ inner: FakeModelTransport) { self.inner = inner }
	var isHeld: Bool { held.withLock { $0 } }
	func release() { gate.release() }

	func stream(_ request: CompletionRequest) -> AsyncThrowingStream<TransportEvent, Error> {
		guard request.charge == .memoryFlush,
			first.withLock({ first in
				defer { first = false }
				return first
			})
		else { return inner.stream(request) }
		return AsyncThrowingStream { continuation in
			let task = Task {
				do {
					held.withLock { $0 = true }
					try await gate.waitUnlessCancelled()
					for try await event in inner.stream(request) { continuation.yield(event) }
					continuation.finish()
				} catch { continuation.finish(throwing: error) }
			}
			continuation.onTermination = { _ in task.cancel() }
		}
	}
}
