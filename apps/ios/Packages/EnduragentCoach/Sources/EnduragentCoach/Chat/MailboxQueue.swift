import Foundation

final class MailboxQueue {
	private(set) var window: OpenWindow?
	private var armed = 0
	private(set) var phase = MailboxPhase.collecting
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
		guard case .collecting = phase, !waiting.isEmpty else { return }
		let next = waiting.removeFirst()
		phase = .running(RunningWork(item: next, task: run(next), live: nil))
	}

	func finish() {
		if case .stopping(let cause, _) = phase {
			phase = .stopping(cause, nil)
		} else {
			phase = .collecting
		}
	}

	func show(_ live: LiveAttempt) {
		switch phase {
		case .collecting:
			return
		case .running(var running):
			running.live = live
			phase = .running(running)
		case .stopping(let cause, var running):
			running?.live = live
			phase = .stopping(cause, running)
		}
	}

	func beginInterruption(_ cause: InterruptionCause) {
		phase = .stopping(cause, phase.running)
	}

	func joinInterruption(isolation: isolated (any Actor)? = #isolation) async {
		await withCheckedContinuation { interrupted.append($0) }
	}

	func endInterruption() {
		phase = .collecting
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
}
