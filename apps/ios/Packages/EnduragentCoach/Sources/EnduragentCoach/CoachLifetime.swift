import Synchronization

extension Coach {
	package final class Lifetime: Sendable {
		private let ended = Mutex(false)

		init() {}

		var terminating: Bool { ended.withLock { $0 } }

		func terminate() {
			ended.withLock { $0 = true }
		}
	}
}
