import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

@Suite(.timeLimit(.minutes(1)))
struct TerminationAdmissionEdgeTests {
	let clock = FixedClock(now: "1998-06-13T08:00:00+02:00", timeZone: "Europe/Amsterdam")

	@Test func willTerminateDuringAStopJoinsAdmission() async throws {
		let transport = FakeModelTransport()
		transport.respond = { _ in ScriptedReply([.hang]) }
		let store = HeldAppendLog(inner: InMemoryRecordLog(), holding: "userMessage", occurrence: 3)
		let coach = await makeCoach(transport: transport, store: store, clock: clock)
		let running = try #require(try await coach.send(draft("one"), to: .main).acceptedTurn)
		try #require(
			try await coach.waitForState(of: running) {
				if case .processing? = $0 { true } else { false }
			} != nil)
		let queued = try #require(try await coach.send(draft("two"), to: .main).acceptedTurn)
		try #require(
			try await firstSnapshot(in: await coach.observe(.main), within: .hangGuard) {
				$0.turns.last?.state == .accepted(.queued(position: 2))
			} != nil)
		async let sent = coach.send(draft("three"), to: .main)
		defer { store.release() }
		try #require(
			try await beforeDeadline(within: .hangGuard) {
				await store.reached.first(where: { _ in true }) != nil
			} == true)
		async let stopped: Void = coach.stop(.main)
		_ = try await coach.waitForState(of: running) { $0.map(isInterrupted) ?? false }
		try await terminateJoiningAdmission(coach, releasing: store.release)
		await stopped
		let third = try #require(try await sent.acceptedTurn)
		#expect(await coach.interruption(of: running) == .athleteStopped)
		for turn in [queued, third] {
			#expect(await coach.interruption(of: turn) == .stoppedBeforeStart)
			#expect(try await settlements(of: turn, in: store).count == 1)
			#expect(try await claims(of: turn, in: store).isEmpty)
		}
	}

	@Test func willTerminateJoinsASendWithoutClaimingIt() async throws {
		let transport = FakeModelTransport()
		transport.respond = ScriptedReply.sequence(
			[.text("Ran."), .finish(reason: .stop)], otherwise: transport.respond)
		let store = HeldAppendLog(inner: InMemoryRecordLog(), holding: "userMessage", occurrence: 1)
		let host = ImmediateExecutionHost()
		let coach = await makeCoach(transport: transport, store: store, clock: clock, host: host)
		async let sent = coach.send(draft("only"), to: .main)
		defer { store.release() }
		try #require(
			try await beforeDeadline(within: .hangGuard) {
				await store.reached.first(where: { _ in true }) != nil
			} == true)
		try await terminateJoiningAdmission(coach, releasing: store.release)
		let turn = try #require(try await sent.acceptedTurn)
		try await Task.sleep(for: .milliseconds(300))
		#expect(host.leases.isEmpty, "a lease began after willTerminate: \(host.leases)")
		#expect(try await claims(of: turn, in: store).isEmpty)
		#expect(transport.requests.isEmpty)
		let reopened = await makeCoach(transport: transport, store: store, clock: clock)
		await reopened.lifecycle(.becameActive)
		#expect(await reopened.state(of: turn) == .accepted(.awaitingRestart))
	}

	@Test func terminationJoinsInitialRecoveryAndRefusesAnUnadmittedSend() async throws {
		let transport = FakeModelTransport()
		transport.respond = ScriptedReply.sequence(
			[.text("Ran."), .finish(reason: .stop)], otherwise: transport.respond)
		let local = InMemoryRecordLog()
		_ = await makeCoach(transport: transport, store: local, clock: clock)
		let store = HeldFirstReadLog(inner: local)
		let host = ImmediateExecutionHost()
		let coach = await makeCoach(
			transport: transport, store: store, clock: clock, host: host, consent: false)
		async let sent = coach.send(draft("first send"), to: .main)
		defer { store.release() }
		try #require(
			try await beforeDeadline(within: .hangGuard) {
				await store.reached.first(where: { _ in true }) != nil
			} == true)
		try await terminateJoiningAdmission(coach, releasing: store.release)
		do {
			_ = try await sent
			Issue.record("An unadmitted send was accepted after termination")
		} catch {
			#expect(error as? AcceptFailure == .storageUnavailable)
		}
		#expect(host.leases.isEmpty)
		#expect(transport.requests.isEmpty)
		#expect(try await local.fetch(RecordQuery(scope: .synced([.userMessage]))).records.isEmpty)
	}

	private func terminateJoiningAdmission(
		_ coach: Coach, releasing release: @escaping @Sendable () -> Void
	) async throws {
		let ended = Gate()
		let shutdown = Task {
			await coach.lifecycle(.willTerminate)
			ended.release()
		}
		defer { shutdown.cancel() }
		let returned = try await beforeDeadline(within: .subject(.milliseconds(100))) {
			try await ended.waitUnlessCancelled()
			return true
		}
		#expect(returned == nil, "Termination returned before joining admission")
		release()
		try #require(
			try await beforeDeadline(within: .hangGuard, onTimeout: release) {
				await shutdown.value
				return true
			} == true)
	}
}
