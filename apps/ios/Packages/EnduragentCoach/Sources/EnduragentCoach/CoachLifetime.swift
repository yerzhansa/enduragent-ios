import Synchronization

extension Coach {
	package final class Lifetime: Sendable {
		private let ended = Mutex(false)
		private let active = Mutex(true)

		init() {}

		var terminating: Bool { ended.withLock { $0 } }
		var foreground: Bool { active.withLock { $0 } }

		func apply(_ event: AppLifecycleEvent) {
			switch event {
			case .becameActive:
				active.withLock { $0 = true }
			case .enteredBackground:
				active.withLock { $0 = false }
			case .willTerminate:
				ended.withLock { $0 = true }
			}
		}
	}
}
