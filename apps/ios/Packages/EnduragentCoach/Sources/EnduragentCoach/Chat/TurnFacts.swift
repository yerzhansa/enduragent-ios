import Foundation

package struct TurnFacts: Sendable, Equatable {
	private static let promptPhrasebook = CatalogPhrasebook(
		tag: .en, locale: LanguageTag.en.defaultLocale)

	package let turn: TurnID
	package let chat: ChatID
	package let origin: DeviceID
	package var legacy = false
	package var fragments: [Fragment] = []
	package var claims: [ClaimedAttempt] = []
	package var replyObserved: [ReplyObservedBody] = []
	package var settlements: [SettledAttempt] = []

	package var requestText: String {
		fragments.sorted { $0.index < $1.index }.map(\.text).joined(separator: "\n")
	}

	package var slash: SlashCommand? {
		fragments.min { $0.index < $1.index }?.slash
	}

	package var latestAttempt: AttemptID? {
		let claimed = claims.map { (attempt: $0.attempt, started: $0.hlc) }
		let unclaimed = settlements.filter { settled in
			!claims.contains { $0.attempt == settled.attempt }
		}.map { (attempt: $0.attempt, started: $0.hlc) }
		return (claimed + unclaimed).max { $0.started < $1.started }?.attempt
	}

	package var latestSettlement: SettledAttempt? {
		guard let latest = latestAttempt else { return nil }
		return settlements.filter { $0.attempt == latest }.max { $0.hlc < $1.hlc }
	}

	package var reply: ReplyText? {
		guard case .replied(let text, _)? = latestSettlement?.settlement else { return nil }
		return text
	}

	package var openClaim: ClaimedAttempt? {
		guard let latest = latestAttempt, latestSettlement == nil else { return nil }
		return claims.first { $0.attempt == latest }
	}

	var lastUlid: ULID {
		(fragments.map(\.ulid) + settlements.map(\.ulid)).max() ?? turn.ulid
	}

	var messageRows: [(ulid: ULID, message: ChatMessage)] {
		guard let userRow else { return [] }
		if let replyRow {
			return [userRow, replyRow]
		}
		return legacy && latestSettlement == nil ? [userRow] : []
	}

	var userRow: (ulid: ULID, message: ChatMessage)? {
		guard let first = fragments.min(by: { $0.index < $1.index }) else { return nil }
		return (
			first.ulid, ChatMessage(author: .athlete(sent: first.ulid.time), text: requestText)
		)
	}

	var replyRow: (ulid: ULID, message: ChatMessage)? {
		guard let settled = latestSettlement else { return nil }
		let replyText: String
		switch settled.settlement {
		case .replied(.model(let text), _):
			replyText = text
		case .interrupted(let partial, _, _) where !partial.isEmpty:
			replyText = partial
		case .savedWork(let outcome, _):
			replyText = AthleteNotices.notice(for: outcome).sentence(in: Self.promptPhrasebook)
		case .interrupted, .failed:
			return nil
		}
		return (
			settled.ulid,
			ChatMessage(author: .coach, text: replyText)
		)
	}
}

package struct ClaimedAttempt: Sendable, Equatable {
	package let hlc: HybridLogicalClock
	package let body: TurnClaimBody

	package var attempt: AttemptID { body.attempt }
	package var process: ProcessID? { body.process }
}

package struct Fragment: Sendable, Equatable {
	package let ulid: ULID
	package let hlc: HybridLogicalClock
	package let civilDate: CivilDate
	package let index: Int
	package let draft: DraftID?
	package let text: String
	package let slash: SlashCommand?
}

package struct SettledAttempt: Sendable, Equatable {
	package let ulid: ULID
	package let hlc: HybridLogicalClock
	package let attempt: AttemptID
	package let settlement: Settlement
}
