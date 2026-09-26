import Foundation

package struct OpenWindow: Sendable, Equatable {
	package let turn: TurnID
	package let closesAt: Date
}

package struct JoinWindow: Sendable {
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
