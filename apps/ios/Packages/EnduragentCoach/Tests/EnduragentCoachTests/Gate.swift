import Synchronization

final class Gate: Sendable {
	private enum State {
		case closed([CheckedContinuation<Void, Never>])
		case open
	}

	private let state = Mutex<State>(.closed([]))
	let reached: AsyncStream<Void>
	private let entered: AsyncStream<Void>.Continuation

	init() {
		(reached, entered) = AsyncStream.makeStream()
	}

	func wait() async {
		await withCheckedContinuation { continuation in
			let open = state.withLock { state in
				switch state {
				case .open:
					return true
				case .closed(var waiters):
					waiters.append(continuation)
					state = .closed(waiters)
					return false
				}
			}
			entered.yield()
			if open { continuation.resume() }
		}
	}

	func waitUnlessCancelled() async throws {
		await withTaskCancellationHandler {
			await wait()
		} onCancel: {
			release()
		}
		try Task.checkCancellation()
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
			return waiters
		}
		for waiter in waiters { waiter.resume() }
	}
}
