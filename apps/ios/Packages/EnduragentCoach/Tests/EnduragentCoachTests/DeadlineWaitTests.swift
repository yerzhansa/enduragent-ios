import EnduragentCoachFixtures
import Foundation
import Synchronization
import Testing

@testable import EnduragentCoach

@Suite(.timeLimit(.minutes(1))) struct DeadlineWaitTests {
	@Test func leaseWaitAllowsAReplyToFinishAfterFiveSeconds() async throws {
		let transport = FakeModelTransport { _ in
			ScriptedReply(
				[.text("Finished."), .finish(reason: .stop)], requestDelay: .seconds(6))
		}
		let host = EndingHost()
		let coach = await makeCoach(
			transport: transport, store: InMemoryRecordLog(), host: host)
		let turn = try #require(try await coach.send(draft("Thursday?"), to: .main).acceptedTurn)
		try await host.waitForEnd(0)
		#expect(replyText(try #require(await coach.state(of: turn))) == "Finished.")
	}

	@Test func heldClockFailsWhenNoSleepArrives() async throws {
		let clock = HeldClock(within: .zero)
		await #expect(throws: TestWaitDeadlineExceeded.self) {
			try await clock.waitUntilHeld(.seconds(7))
		}
	}

	@Test func heldClockFailsWhenASleepIsNeverReleased() async throws {
		let clock = HeldClock(within: .zero)
		await #expect(throws: CancellationError.self) {
			try await clock.sleep(for: .seconds(7))
		}
		#expect(clock.held.isEmpty)
		#expect(clock.slept.isEmpty)
		#expect(clock.uptime == .zero)
	}

	@Test func reviewGateFailsWhenNoRefreshEnters() async throws {
		let gate = ReviewGate(within: .zero)
		let entered = try await gate.waitUntilEntered()
		#expect(entered == false)
	}

	@Test func reviewGateFailsWhenARefreshIsNeverReleased() async throws {
		let gate = ReviewGate(within: .zero)
		await gate.arm()
		let rescue = Task {
			try await Task.sleep(for: .seconds(1))
			await gate.release()
		}
		defer { rescue.cancel() }
		await #expect(throws: TestWaitDeadlineExceeded.self) {
			try await gate.pass()
		}
	}

	@Test func deadlineReleasesAHeldTaskBeforeJoiningIt() async throws {
		let gate = Gate()
		defer { gate.release() }
		let held = Task { await gate.wait() }
		defer { held.cancel() }
		try #require(
			try await beforeDeadline(within: .seconds(5)) {
				await gate.waitUntilParked()
			} != nil)
		let rescue = Task {
			try await Task.sleep(for: .seconds(1))
			gate.release()
		}
		defer { rescue.cancel() }
		let released = Mutex(false)
		let value = try await beforeDeadline(
			within: .milliseconds(20),
			onTimeout: {
				released.withLock { $0 = true }
				held.cancel()
				gate.release()
			}
		) {
			await held.value
		}
		#expect(value == nil)
		#expect(released.withLock { $0 })
	}

	@Test func completedEventReturnsItsValue() async throws {
		let gate = Gate()
		gate.release()
		let value = try await beforeDeadline(within: .seconds(5)) {
			try await gate.waitUnlessCancelled()
			return "arrived"
		}
		#expect(value == "arrived")
	}

	@Test func missingEventCancelsItsWaitAtTheDeadline() async throws {
		let gate = Gate()
		let value = try await beforeDeadline(within: .zero) {
			try await gate.waitUnlessCancelled()
		}
		#expect(value == nil)
	}

	@Test func cancellingABoundedWaitCancelsItsParkedEvent() async throws {
		let gate = Gate()
		let waiting = Task {
			try await beforeDeadline(within: .seconds(5)) {
				try await gate.waitUnlessCancelled()
			}
		}
		defer { waiting.cancel() }
		try #require(
			try await beforeDeadline(within: .seconds(5)) {
				await gate.waitUntilParked()
			} != nil,
			"Event wait did not park within five seconds")
		waiting.cancel()
		await #expect(throws: CancellationError.self) { try await waiting.value }
	}
}
