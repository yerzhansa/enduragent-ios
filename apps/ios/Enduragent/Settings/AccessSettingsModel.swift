import EnduragentCoach
import Observation

@MainActor
@Observable
final class AccessSettingsModel {
	private(set) var notice: AthleteNotice?
	private(set) var isChanging = false
	private let environment: AppEnvironment

	init(environment: AppEnvironment) {
		self.environment = environment
	}

	func dismiss() {
		notice = nil
	}

	func choose(_ change: ModelAccessChange) async {
		guard !isChanging else { return }
		isChanging = true
		defer { isChanging = false }
		notice = nil
		let coach = environment.services.coach
		if change == .useCredits {
			do {
				if try await coach.creditsIdentity().hasCreditsKey == false {
					let token = try await environment.deviceCheck.token()
					notice = await coach.claimStarter(deviceCheck: token)
					guard try await coach.creditsIdentity().hasCreditsKey else { return }
				}
			} catch {
				notice = AthleteNotice.credits(failure: error)
				return
			}
		}
		let outcome = await coach.changeModelAccess(change)
		if let failure = outcome.notice { notice = failure }
	}
}
