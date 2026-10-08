import EnduragentCoach
import Observation

@MainActor
@Observable
final class AccessSettingsModel {
	private(set) var notice: AthleteNotice?
	private var changing: (change: ModelAccessChange, task: Task<Void, Never>)?
	var isChanging: Bool { changing != nil }
	private let environment: AppEnvironment

	init(environment: AppEnvironment) {
		self.environment = environment
	}

	func dismiss() {
		notice = nil
	}

	func choose(_ change: ModelAccessChange) async {
		if let changing {
			if change == .signInToOpenRouter && changing.change == change {
				await changing.task.value
			}
			return
		}
		let task = Task { await apply(change) }
		changing = (change, task)
		await task.value
		changing = nil
	}

	private func apply(_ change: ModelAccessChange) async {
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
