import Foundation

extension Coach {
	public func claimStarter(deviceCheck: Data) async -> AthleteNotice {
		do {
			let outcome = try await credits.grant(deviceCheck: deviceCheck)
			let key: CatalogKey
			let amount: Credits
			switch outcome {
			case .minted(let credits):
				key = Catalog.creditsBalance
				amount = credits
			case .toppedUp(let added):
				key = Catalog.onboardingStarterAdded
				amount = added
			case .alreadyGranted:
				guard try await creditsIdentity().hasCreditsKey else {
					return AthleteNotice(key: Catalog.onboardingStarterAlreadyGranted, actions: [])
				}
				key = Catalog.creditsBalance
				amount = try await credits.balance().credits
			}
			return AthleteNotice(
				key: key, count: amount.units, vars: ["formattedCount": .integer(amount.units)],
				actions: [])
		} catch {
			return AthleteNotice.credits(failure: error)
		}
	}
}
