import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

@Suite(.timeLimit(.minutes(1)))
struct AdmissionLifetimeTests {
	@Test func terminationJoinsAdmissionAndReleasesItsStoreOwner() async throws {
		let timer = HeldClock()
		let window = Duration.seconds(60)
		defer { timer.release(window) }
		weak var releasedCoach: Coach?
		weak var releasedLog: FaultInjectingRecordLog?
		do {
			let log = FaultInjectingRecordLog(wrapping: InMemoryRecordLog())
			let held = HeldAppendLog(inner: log, holding: "userMessage", occurrence: 1)
			defer { held.release() }
			let transport = FakeModelTransport()
			let host = ImmediateExecutionHost()
			let coach = await makeCoach(
				transport: transport, store: held,
				coalescing: CoalescingPolicy(window: window), host: host, coalescingClock: timer)
			releasedCoach = coach
			releasedLog = log
			async let sent = beforeDeadline(within: .seconds(10), onTimeout: held.release) {
				try await coach.send(draft("Admission interrupted"), to: .main)
			}
			try #require(
				try await beforeDeadline(within: .seconds(5)) {
					await held.reached.first(where: { _ in true }) != nil
				} == true)
			let ended = Gate()
			let shutdown = Task {
				await coach.lifecycle(.willTerminate)
				ended.release()
			}
			defer { shutdown.cancel() }
			let returned = try await beforeDeadline(within: .milliseconds(100)) {
				try await ended.waitUnlessCancelled()
				return true
			}
			#expect(returned == nil, "Termination returned before joining the pending admission")
			held.release()
			let turn = try #require(try await sent?.acceptedTurn)
			try #require(
				try await beforeDeadline(within: .seconds(5)) {
					await shutdown.value
					return true
				} == true)
			#expect(timer.held.isEmpty, "Admission armed a timer after termination")
			#expect(transport.requests.isEmpty)
			#expect(host.leases.isEmpty)
			#expect(try await claims(of: turn, in: log).isEmpty)
			#expect(try await settlements(of: turn, in: log).isEmpty)
			#expect(
				try await log.fetch(RecordQuery(scope: .synced([.userMessage]), turn: turn))
					.records.count == 1)
		}
		let deadline = ContinuousClock.now + .seconds(5)
		while releasedCoach != nil || releasedLog != nil, ContinuousClock.now < deadline {
			try await Task.sleep(for: .milliseconds(10))
		}
		#expect(releasedCoach == nil, "Coach survived completed termination")
		#expect(releasedLog == nil, "The store owner survived completed termination")
	}

	@Test func terminationJoinsOpeningAndFencesNewMailboxes() async throws {
		let log = InMemoryRecordLog()
		let held = HeldConversationReadLog(inner: log)
		defer { held.gate.release() }
		let transport = FakeModelTransport()
		let host = ImmediateExecutionHost()
		let coach = await makeCoach(transport: transport, store: held, host: host)
		async let opened = beforeDeadline(within: .seconds(10), onTimeout: held.gate.release) {
			await coach.observe(.main)
		}
		try #require(
			try await beforeDeadline(within: .seconds(5)) {
				await held.reached.first(where: { _ in true }) != nil
			} == true)
		let ended = Gate()
		let shutdown = Task {
			await coach.lifecycle(.willTerminate)
			ended.release()
		}
		defer { shutdown.cancel() }
		let returned = try await beforeDeadline(within: .milliseconds(100)) {
			try await ended.waitUnlessCancelled()
			return true
		}
		#expect(returned == nil, "Termination returned before joining mailbox opening")
		held.gate.release()
		_ = try #require(try await opened)
		try #require(
			try await beforeDeadline(within: .seconds(5)) {
				await shutdown.value
				return true
			} == true)
		for chat: ChatID in [.main, "never-opened"] {
			await #expect(throws: AcceptFailure.storageUnavailable) {
				try await coach.send(draft("After termination"), to: chat)
			}
		}
		#expect(transport.requests.isEmpty)
		#expect(host.leases.isEmpty)
		#expect(try await log.fetch(RecordQuery(scope: .synced([.userMessage]))).records.isEmpty)
	}
}
