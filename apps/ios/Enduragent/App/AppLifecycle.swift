import EnduragentCoach
import Foundation
import UIKit

@MainActor
final class AppLifecycle {
	private let builder: ServicesBuilder
	private var termination: (any NSObjectProtocol)?

	init(builder: ServicesBuilder) {
		self.builder = builder
		termination = NotificationCenter.default.addObserver(
			forName: UIApplication.willTerminateNotification, object: nil, queue: nil
		) { [weak self] _ in
			MainActor.assumeIsolated { self?.terminate() }
		}
	}

	isolated deinit {
		if let termination {
			NotificationCenter.default.removeObserver(termination)
		}
	}

	func forward(_ event: AppLifecycleEvent) async {
		await builder.services?.coach.lifecycle(event)
	}

	private func terminate() {
		guard let coach = builder.services?.coach else { return }
		let interrupted = DispatchSemaphore(value: 0)
		Task.detached(priority: Task.currentPriority) {
			await coach.lifecycle(.willTerminate)
			interrupted.signal()
		}
		interrupted.wait()
	}
}
