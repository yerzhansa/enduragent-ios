import EnduragentCoach
import Observation

@MainActor
@Observable
final class CreditsModel {
	private(set) var balance: Credits?
	private(set) var catalog: PackCatalog?
	private(set) var notice: AthleteNotice?
	private(set) var packPrices: [String: String] = [:]
	private let services: AppServices

	init(services: AppServices) {
		self.services = services
	}

	func load() async {
		balance = nil
		catalog = nil
		packPrices = [:]
		notice = nil
		do {
			let loaded = try await services.coach.credits.catalog()
			catalog = loaded
			let held = try await services.coach.credits.balance()
			balance = held.credits
			packPrices = try await services.packPrices(loaded.packs.map(\.id))
			notice = held.notice
		} catch {
			balance = nil
			packPrices = [:]
			notice = AthleteNotice.credits(failure: error)
		}
	}
}
