import Foundation
import Synchronization

@testable import EnduragentCoach

final class HeldClock: Clock {
	private let calendar: FixedClock
	private let state = Mutex(State())
	private let onSleep: @Sendable (Duration) -> Void

	private struct Sleeper {
		let id: UUID
		let duration: Duration
		let deadline: Duration
		let gate: Gate
	}

	private struct State {
		var sleepers: [Sleeper] = []
		var slept: [Duration] = []
		var changed = Gate()
	}

	init(
		calendar: FixedClock = FixedClock(
			now: "1998-06-13T08:00:00+02:00", timeZone: "Europe/Amsterdam"),
		onSleep: @escaping @Sendable (Duration) -> Void = { _ in }
	) {
		self.calendar = calendar
		self.onSleep = onSleep
	}

	var now: Date { calendar.now }
	var timeZone: TimeZone { calendar.timeZone }
	var uptime: Duration { calendar.uptime }
	var held: [Duration] { state.withLock { $0.sleepers.map(\.duration) } }
	var slept: [Duration] { state.withLock { $0.slept } }

	func sleep(for duration: Duration) async throws {
		let id = UUID()
		let gate = Gate()
		await withTaskCancellationHandler {
			let changed = state.withLock { state in
				state.sleepers.append(
					Sleeper(id: id, duration: duration, deadline: uptime + duration, gate: gate))
				defer { state.changed = Gate() }
				return state.changed
			}
			changed.release()
			onSleep(duration)
			if Task.isCancelled { cancel(id) }
			await gate.wait()
		} onCancel: {
			cancel(id)
		}
		try Task.checkCancellation()
		state.withLock { $0.slept.append(duration) }
	}

	func advance(by duration: Duration) {
		let released = state.withLock { state in
			calendar.advance(by: duration.timeInterval)
			let ready = state.sleepers.filter { $0.deadline <= uptime }
			state.sleepers.removeAll { $0.deadline <= uptime }
			defer { state.changed = Gate() }
			return (ready, state.changed)
		}
		for sleeper in released.0 { sleeper.gate.release() }
		released.1.release()
	}

	func release(_ duration: Duration) {
		let released = state.withLock { state in
			let ready = state.sleepers.filter { $0.duration == duration }
			if let deadline = ready.map(\.deadline).max() {
				calendar.advance(by: max(.zero, deadline - uptime).timeInterval)
			}
			state.sleepers.removeAll { $0.duration == duration }
			defer { state.changed = Gate() }
			return (ready, state.changed)
		}
		for sleeper in released.0 { sleeper.gate.release() }
		released.1.release()
	}

	func waitUntilHeld(_ duration: Duration) async throws {
		while let changed = state.withLock({ state in
			state.sleepers.contains { $0.duration == duration } ? nil : state.changed
		}) {
			try await changed.waitUnlessCancelled()
		}
	}

	private func cancel(_ id: UUID) {
		let removed = state.withLock { state in
			let sleeper = state.sleepers.first { $0.id == id }
			state.sleepers.removeAll { $0.id == id }
			defer { state.changed = Gate() }
			return (sleeper, state.changed)
		}
		removed.0?.gate.release()
		removed.1.release()
	}
}
