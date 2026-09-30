import Foundation

final class MailboxQueue {
	private(set) var window: OpenWindow?
	private var armed = 0
	private(set) var phase = MailboxPhase.idle
	private(set) var waiting: [MailboxWork] = []
	private var interrupted: [CheckedContinuation<Void, Never>] = []

	var isEmpty: Bool { waiting.isEmpty }

	var next: MailboxWork? { waiting.first }

	func add(_ turn: TurnID) -> Bool {
		append(.turn(turn))
	}

	func add(_ reset: ResetID) -> Bool {
		append(.reset(reset))
	}

	func arm(_ turn: TurnID, at now: Date, for duration: Duration) -> Int {
		armed += 1
		window = OpenWindow(turn: turn, closesAt: now.addingTimeInterval(duration.timeInterval))
		return armed
	}

	func closeWindow(ifArmed generation: Int? = nil) -> TurnID? {
		guard let window, generation == nil || generation == armed else { return nil }
		self.window = nil
		return window.turn
	}

	func add(_ job: FlushJobID) -> Bool {
		append(.flush(job))
	}

	func start(_ run: (MailboxWork) -> Task<Void, Never>) {
		guard case .idle = phase, !waiting.isEmpty else { return }
		let next = waiting.removeFirst()
		phase = .running(.active(next, run(next), nil))
	}

	func finish() {
		if case .stopping(let cause, _) = phase {
			phase = .stopping(cause, nil)
		} else {
			phase = .idle
		}
	}

	func finishTurn() {
		guard let running = phase.running else {
			preconditionFailure("A finishing turn must retain its running task")
		}
		update(.finishing(running.task))
	}

	func show(_ live: LiveAttempt) {
		guard case .active(let item, let task, _)? = phase.running else { return }
		update(.active(item, task, live))
	}

	func beginInterruption(_ cause: InterruptionCause) {
		phase = .stopping(cause, phase.running)
	}

	func joinInterruption(isolation: isolated (any Actor)? = #isolation) async {
		await withCheckedContinuation { interrupted.append($0) }
	}

	func endInterruption() {
		guard case .stopping(_, nil) = phase else {
			preconditionFailure("An interruption must join its running task before ending")
		}
		phase = .idle
		while let waiting = interrupted.popLast() {
			waiting.resume()
		}
	}

	func dropWaiting() -> [TurnID] {
		defer { waiting.removeAll { $0.reset == nil } }
		return waiting.compactMap(\.turn)
	}

	private func append(_ item: MailboxWork) -> Bool {
		guard !waiting.contains(item) else { return false }
		waiting.append(item)
		return true
	}

	private func update(_ running: RunningWork) {
		if let cause = phase.cause {
			phase = .stopping(cause, running)
		} else {
			phase = .running(running)
		}
	}
}
