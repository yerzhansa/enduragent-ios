import EnduragentCoach
import Foundation
import UIKit

@MainActor
final class AppLifecycle {
	private static let terminationBudget: DispatchTimeInterval = .seconds(4)

	private let environment: AppEnvironment
	private var termination: (any NSObjectProtocol)?

	init(environment: AppEnvironment) {
		self.environment = environment
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
		await environment.services.coach.lifecycle(event)
	}

	private func terminate() {
		let coach = environment.services.coach
		let interrupted = DispatchSemaphore(value: 0)
		Task.detached(priority: Task.currentPriority) {
			await coach.lifecycle(.willTerminate)
			interrupted.signal()
		}
		_ = interrupted.wait(timeout: .now() + Self.terminationBudget)
	}
}
