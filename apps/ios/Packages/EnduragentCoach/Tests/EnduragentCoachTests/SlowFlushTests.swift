import Foundation
import Synchronization
import Testing

@testable import EnduragentCoach

@Suite struct SlowFlushTests {
	@Test(arguments: [nil, "7"] as [String?])
	func slowSaveSettlesWithNormalRequestDeadlines(retryAfter: String?) async throws {
		let clock = FixedClock(now: "1998-06-13T12:00:00+02:00", timeZone: "Europe/Amsterdam")
		let store = InMemoryRecordLog()
		let transport = FakeModelTransport()
		try await seedHistory(store, clock: clock, turns: 1, tokens: 200)
		transport.flushScript = [
			.toolCall(
				name: "memory_write",
				arguments: #"{"section":"schedule","content":"Group ride on Saturdays."}"#),
			.finish(reason: .toolCalls),
		]
		if let retryAfter {
			transport.flushScript.append(
				.fail(.http(status: 429, headers: ["Retry-After": retryAfter])))
		}
		transport.flushScript += [
			.toolCall(
				name: "ledger_append",
				arguments: #"{"kind":"decision","date":"1998-06-13","text":"Keep Saturdays free"}"#),
			.finish(reason: .toolCalls), .finish(reason: .stop),
		]
		let slow = SlowFlushTransport(inner: transport, clock: clock)
		let coach = Coach(
			sport: .cycling,
			ports: CoachPorts(
				records: RecordStore(log: store), secrets: keyedSecrets(),
				models: ModelService { _ in slow },
				training: .fake { _, _ in FakeIntervalsClient(athleteName: "Ada", ftp: 250) },
				credits: .fake(FakeCreditsClient()), host: ImmediateExecutionHost(), clock: clock
			), builtInModel: testModel, deviceLanguage: .en, coalescing: quickWindow)
		_ = await consentingCoach(coach)
		#expect(await coach.startNewConversation(in: .main) == .started(memory: .saved))
		#expect(clock.uptime == .seconds(retryAfter == nil ? 15 : 22))
		#expect(clock.slept == (retryAfter == nil ? [] : [.seconds(7)]))
		#expect(
			sent(.memoryFlush, by: transport).map(\.deadline)
				== Array(repeating: .seconds(600), count: retryAfter == nil ? 3 : 4))
		let view = try await coach.memory.view()
		#expect(view.sections["schedule"]?.contains("Group ride on Saturdays.") == true)
		let hits = try await coach.memory.query(
			from: "1998-06-13", to: "1998-06-13", contains: "Keep Saturdays free")
		#expect(hits.count == 1)
		let ledger = Ledger(log: store, clock: clock, diagnostics: DiagnosticsLog(clock: clock))
		let jobs = try await ledger.flushJobs(in: try await ledger.conversation(.main))
		#expect(jobs.count == 1)
		#expect(jobs.allSatisfy { $0.settled && !$0.abandoned })
	}
}

private final class SlowFlushTransport: ModelTransport {
	let inner: FakeModelTransport
	let clock: FixedClock
	private let first = Mutex(true)

	init(inner: FakeModelTransport, clock: FixedClock) {
		self.inner = inner
		self.clock = clock
	}

	func stream(_ request: CompletionRequest) -> AsyncThrowingStream<TransportEvent, Error> {
		if request.charge == .memoryFlush,
			first.withLock({ pending in
				defer { pending = false }
				return pending
			})
		{
			clock.advance(by: 15)
		}
		return inner.stream(request)
	}
}
