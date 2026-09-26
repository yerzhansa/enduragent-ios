import Foundation

package struct TurnFacts: Sendable, Equatable {
	private static let promptPhrasebook = CatalogPhrasebook(
		tag: .en, locale: LanguageTag.en.defaultLocale)

	package let turn: TurnID
	package let chat: ChatID
	package let origin: DeviceID
	package var legacy = false
	package var fragments: [Fragment] = []
	package var claims: [TurnClaimBody] = []
	package var replyObserved: [ReplyObservedBody] = []
	package var settlements: [SettledAttempt] = []

	package var requestText: String {
		fragments.sorted { $0.index < $1.index }.map(\.text).joined(separator: "\n")
	}

	package var slash: SlashCommand? {
		fragments.min { $0.index < $1.index }?.slash
	}

	package var latestSettlement: SettledAttempt? {
		settlements.max { $0.hlc < $1.hlc }
	}

	package var openClaims: [TurnClaimBody] {
		claims.filter { claim in !settlements.contains { $0.attempt == claim.attempt } }
	}

	var lastUlid: ULID {
		(fragments.map(\.ulid) + settlements.map(\.ulid)).max() ?? turn.ulid
	}

	var messageRows: [(ulid: ULID, message: ChatMessage)] {
		guard let first = fragments.min(by: { $0.index < $1.index }) else { return [] }
		let question = (
			first.ulid, ChatMessage(role: .user, text: requestText, civilDate: first.civilDate)
		)
		guard let settled = latestSettlement else {
			return legacy ? [question] : []
		}
		let replyText: String
		switch settled.settlement {
		case .replied(.model(let text), _):
			replyText = text
		case .interrupted(let partial, _, _) where !partial.isEmpty:
			replyText = partial
		case .savedWork(let outcome, _):
			replyText = AthleteNotices.notice(for: outcome).sentence(in: Self.promptPhrasebook)
		case .interrupted, .failed:
			return []
		}
		return [
			question,
			(
				settled.ulid,
				ChatMessage(role: .assistant, text: replyText, civilDate: settled.civilDate)
			),
		]
	}
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
	package let civilDate: CivilDate
	package let attempt: AttemptID
	package let settlement: Settlement
}
