public enum AthleteOwnership: Sendable, Equatable {
	case verified(IntervalsAthleteID)
	case unverified
}

public struct AthleteAttribution: Sendable, Equatable {
	public let ownership: AthleteOwnership
	private let hasChangedAthlete: Bool

	init(accounts: [TrainingAccount], using information: InformationOwnership, device: DeviceID) {
		let owners = Set(accounts.map { information.rowOwner(account: $0) })
		if owners.count == 1, case .athlete(let athlete) = owners.first {
			ownership = .verified(athlete)
		} else {
			ownership = .unverified
		}
		hasChangedAthlete = information.hasChangedAthlete(on: device)
	}

	public func historyLine(
		in phrasebook: CatalogPhrasebook, connectedAthlete: IntervalsAthleteID?
	) -> String? {
		guard hasChangedAthlete, case .verified(let athlete) = ownership,
			athlete != connectedAthlete
		else { return nil }
		return phrasebook.say(Catalog.archiveSavedForAnotherAthlete, ["id": athlete.rawValue])
	}

}

extension Segment {
	func attribution(using ownership: InformationOwnership, device: DeviceID) -> AthleteAttribution
	{
		let accounts =
			turns.flatMap { facts in
				(facts.userRow.map { [$0.account] } ?? [])
					+ facts.questions.map(\.row.account) + facts.claims.map(\.account)
			} + notes.map(\.account)
		return AthleteAttribution(accounts: accounts, using: ownership, device: device)
	}
}
