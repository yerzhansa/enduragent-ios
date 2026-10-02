import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

extension StopAndLeaseEdgeTests {
	@Test(arguments: [
		InterruptionCause.athleteStopped, .systemExpired, .appTerminating,
	])
	func interruptionCancelsInFlightRead(cause: InterruptionCause) async throws {
		let readClock = HeldClock()
		defer { readClock.release(.seconds(30)) }
		let intervals = HeldReadIntervals(clock: readClock)
		let transport = FakeModelTransport()
		transport.respond = ScriptedReply.sequence(
			[
				.text("Checking your recent rides. "),
				.toolCall(name: "intervals_fetch_activities", arguments: #"{"days":7}"#),
				.finish(reason: .toolCalls),
			], otherwise: transport.respond)
		let store = InMemoryRecordLog()
		let host = ImmediateExecutionHost()
		let coach = await makeCoach(
			transport: transport, intervals: intervals, store: store, clock: clock, host: host)
		let turn = try #require(
			try await coach.send(draft("How was my week?"), to: .main).acceptedTurn)
		try await readClock.waitUntilHeld(.seconds(30))
		let snapshots = await coach.observe(.main)
		let interruption = Task {
			switch cause {
			case .athleteStopped:
				await coach.stop(.main)
			case .systemExpired:
				await host.expire(.systemExpired)
			case .appTerminating:
				await coach.lifecycle(.willTerminate)
			default:
				Issue.record("unsupported interruption: \(cause)")
			}
			return true
		}
		defer { interruption.cancel() }
		_ = try #require(
			try await firstSnapshot(in: snapshots, within: .hangGuard) { $0.activity == .stopping })
		_ = await coach.currentSnapshot(.main)
		try await waitUntil { readClock.held.isEmpty }
		#expect(readClock.held.isEmpty, "the training read did not receive cancellation")
		readClock.release(.seconds(30))
		let interruptedRead = try await beforeDeadline(
			within: .hangGuard, onTimeout: { readClock.release(.seconds(30)) }
		) {
			await interruption.value
		}
		try #require(interruptedRead == true)
		guard case .interrupted(let interrupted)? = await coach.state(of: turn) else {
			Issue.record("expected the reply to be interrupted")
			return
		}
		#expect(interrupted.cause == cause)
		#expect(interrupted.partial == "Checking your recent rides. ")
		#expect(try await settlements(of: turn, in: store).count == 1)
		#expect(await host.ended(0)?.ending == .interrupted(cause))
		#expect(
			!coach.diagnostics.entries.contains {
				if case .toolFailed = $0.event { return true }
				return false
			})
	}
}
