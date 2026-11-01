import Foundation
import Synchronization

final class Gate: Sendable {
	private enum State {
		case closed([UUID: CheckedContinuation<Void, Never>])
		case open
	}

	private let state = Mutex<State>(.closed([:]))
	let reached: AsyncStream<Void>
	private let entered: AsyncStream<Void>.Continuation

	init() {
		(reached, entered) = AsyncStream.makeStream()
	}

	func wait() async {
		await park(UUID(), cancellable: false)
	}

	func waitUnlessCancelled() async throws {
		let id = UUID()
		await withTaskCancellationHandler {
			await park(id, cancellable: true)
		} onCancel: {
			cancel(id)
		}
		try Task.checkCancellation()
	}

	private func park(_ id: UUID, cancellable: Bool) async {
		await withCheckedContinuation { continuation in
			let open = state.withLock { state in
				if cancellable && Task.isCancelled { return true }
				switch state {
				case .open:
					return true
				case .closed(var waiters):
					waiters[id] = continuation
					state = .closed(waiters)
					return false
				}
			}
			entered.yield()
			if open { continuation.resume() }
		}
	}

	private func cancel(_ id: UUID) {
		let waiter = state.withLock { state -> CheckedContinuation<Void, Never>? in
			guard case .closed(var waiters) = state else { return nil }
			let waiter = waiters.removeValue(forKey: id)
			state = .closed(waiters)
			return waiter
		}
		waiter?.resume()
	}

	func waitUntilParked() async {
		var arrivals = reached.makeAsyncIterator()
		await arrivals.next()
	}

	func release() {
		let waiters = state.withLock { state in
			guard case .closed(let waiters) = state else {
				return [CheckedContinuation<Void, Never>]()
			}
			state = .open
			return Array(waiters.values)
		}
		for waiter in waiters { waiter.resume() }
	}
}
