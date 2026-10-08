import EnduragentCoach
import Foundation
import Observation

@MainActor
@Observable
final class OnboardingModel {
	private(set) var starterNotice: AthleteNotice?
	private(set) var starterResolved = false
	private var starterLoaded = false
	private let environment: AppEnvironment

	static let completedKey = "enduragent.onboardingCompleted"

	init(environment: AppEnvironment) {
		self.environment = environment
	}

	var isCompleted: Bool {
		environment.defaults.bool(forKey: Self.completedKey)
	}

	func complete() {
		environment.defaults.set(true, forKey: Self.completedKey)
	}

	func loadStarter() async {
		guard !starterLoaded else { return }
		starterLoaded = true
		do {
			let token = try await environment.deviceCheck.token()
			let notice = await environment.services.coach.claimStarter(deviceCheck: token)
			starterNotice = notice
		} catch {
			starterNotice = AthleteNotice.credits(failure: error)
		}
		starterResolved = true
	}

}
