import Foundation

extension Segment {
	package func promptHistory(
		excluding turn: TurnID?, for account: TrainingAccount, device: DeviceID,
		using ownership: InformationOwnership
	) -> PromptHistory {
		let scope = ownership.scope(for: account, device: device)
		let owner: InformationOwner
		switch scope {
		case .athlete(let athlete): owner = .athlete(athlete)
		case .beforeFirstConnection(let device): owner = .unbound(device)
		case .unavailable: return PromptHistory(summary: nil, rows: [])
		}
		let window = promptWindows[owner]
		let rows = historyRows(excluding: turn, using: ownership).filter {
			scope.contains($0, using: ownership)
		}
		return PromptHistory(summary: window?.summary?.markdown, rows: rows)
	}
	func historyRows(excluding turn: TurnID?, using ownership: InformationOwnership)
		-> [ConversationRow]
	{
		turns.filter { $0.turn != turn }.flatMap { facts in
			let rows = visibleRows(of: facts)
			return rows.filter { row in
				let owner = ownership.rowOwner(account: row.account, origin: row.origin)
				guard let trim = promptWindows[owner]?.trim else { return true }
				return !rows.filter {
					ownership.rowOwner(account: $0.account, origin: $0.origin) == owner
				}
				.allSatisfy { trim.messageUlids.contains($0.ulid) }
			}
		}
	}

}

extension InformationReadScope {
	func contains(_ row: ConversationRow, using ownership: InformationOwnership) -> Bool {
		if case .beforeFirstConnection(let device) = self {
			return row.account == .unconnected && row.origin == device
		}
		return contains(ownership.rowOwner(account: row.account, origin: row.origin))
	}
}
