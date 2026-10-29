import EnduragentCoach
import Observation

@MainActor
@Observable
final class CreditsModel {
	private(set) var balance: Credits?
	private(set) var notice: AthleteNotice?
	private let services: AppServices

	init(services: AppServices) {
		self.services = services
	}

	func load() async {
		balance = nil
		notice = nil
		do {
			let held = try await services.coach.credits.balance()
			balance = held.credits
			notice = held.notice
		} catch {
			notice = AthleteNotice.credits(failure: error)
		}
	}
}
