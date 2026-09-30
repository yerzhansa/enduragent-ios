import Foundation

extension ChatMailbox.Admitted {
	func add(_ turn: TurnID, origin: AttemptOrigin) -> Bool {
		queue.append(.turn(turn, origin: origin))
	}

	func add(_ reset: ResetID) -> Bool {
		queue.append(.reset(reset))
	}

	func arm(
		_ turn: TurnID, at now: Date, for duration: Duration,
		then close: @escaping @Sendable (Int) async -> Void
	) {
		queue.joining.arm(turn, at: now, for: duration, then: close)
	}

	func closeWindow(ifArmed armed: Int? = nil) -> TurnID? {
		queue.joining.close(ifArmed: armed)
	}
}

final class MailboxQueue {
	fileprivate var joining = JoinWindow()
	private(set) var active: MailboxWork?
	private var waiting: [MailboxWork] = []

	var window: OpenWindow? { joining.open }

	var isEmpty: Bool { waiting.isEmpty }

	var next: MailboxWork? { waiting.first }

	var resetting: Bool {
		active?.reset != nil || waiting.contains { $0.reset != nil }
	}

	func turns(includingActive: Bool) -> [TurnID] {
		let items = includingActive ? [active].compactMap { $0 } + waiting : waiting
		return items.compactMap(\.turn)
	}

	func add(_ job: FlushJobID) -> Bool {
		append(.flush(job))
	}

	func start() -> MailboxWork? {
		guard !waiting.isEmpty else { return nil }
		active = waiting.removeFirst()
		return active
	}

	func finish() {
		active = nil
	}

	func dropWaiting() -> [TurnID] {
		defer { waiting.removeAll { $0.reset == nil } }
		return turns(includingActive: false)
	}

	fileprivate func append(_ item: MailboxWork) -> Bool {
		guard !waiting.contains(item) else { return false }
		waiting.append(item)
		return true
	}
}

private struct JoinWindow: Sendable {
	private(set) var open: OpenWindow?
	private var armed = 0

	mutating func arm(
		_ turn: TurnID, at now: Date, for duration: Duration,
		then close: @escaping @Sendable (Int) async -> Void
	) {
		armed += 1
		let generation = armed
		open = OpenWindow(turn: turn, closesAt: now.addingTimeInterval(duration.timeInterval))
		Task {
			do {
				try await Task.sleep(for: duration)
			} catch is CancellationError {
				return
			} catch {
				fatalError("Task.sleep failed: \(error)")
			}
			await close(generation)
		}
	}

	mutating func close(ifArmed generation: Int? = nil) -> TurnID? {
		guard let open, generation == nil || generation == armed else { return nil }
		self.open = nil
		return open.turn
	}
}
