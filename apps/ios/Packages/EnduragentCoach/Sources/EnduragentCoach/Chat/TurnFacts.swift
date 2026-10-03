import Foundation

package struct TurnFacts: Sendable, Equatable {
	private static let promptPhrasebook = CatalogPhrasebook(tag: .en)

	package let turn: TurnID
	package let chat: ChatID
	package let origin: DeviceID
	package var legacy = false
	package var fragments: [Fragment] = []
	package var claims: [ClaimedAttempt] = []
	package var replyObserved: [ReplyObservedBody] = []
	package var settlements: [SettledAttempt] = []
	package var reviewWrites: [CalendarWriteKey: CalendarWriteEvidence] = [:]

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
		guard let latest = latestAttempt,
			let settled = settlements.filter({ $0.attempt == latest }).max(by: { $0.hlc < $1.hlc })
		else { return nil }
		return SettledAttempt(
			ulid: settled.ulid, hlc: settled.hlc, attempt: settled.attempt,
			settlement: settled.settlement.resolvingCalendarWrites(
				evidence: Array(reviewWrites.values)), origin: settled.origin,
			account: settled.account)
	}

	package var reply: ReplyText? {
		guard case .replied(let text, _)? = latestSettlement?.settlement else { return nil }
		return text
	}

	package var openClaim: ClaimedAttempt? {
		guard let latest = latestAttempt, latestSettlement == nil else { return nil }
		return claims.first { $0.attempt == latest }
	}

	var messageRows: [ConversationRow] {
		guard let userRow else { return [] }
		if let replyRow {
			return [userRow, replyRow]
		}
		return legacy && latestSettlement == nil ? [userRow] : []
	}

	var userRow: ConversationRow? {
		guard let first = fragments.min(by: { $0.index < $1.index }) else { return nil }
		return ConversationRow(
			ulid: first.ulid, origin: origin,
			account: first.account == .unconnected
				? originalAttemptAccount ?? first.account : first.account,
			message: ChatMessage(
				author: .athlete(sent: first.ulid.time, timeZone: first.timeZone), text: requestText
			)
		)
	}

	private var originalAttemptAccount: TrainingAccount? {
		guard
			let attempt = (claims.map(\.attempt) + settlements.map(\.attempt))
				.min(by: { $0.ulid < $1.ulid })
		else { return nil }
		return claims.first { $0.attempt == attempt }?.account
			?? settlements.filter { $0.attempt == attempt }.min(by: { $0.hlc < $1.hlc })?.account
	}

	var replyRow: ConversationRow? {
		guard let settled = latestSettlement else { return nil }
		let replyText: String
		switch settled.settlement {
		case .replied(let reply, _):
			replyText = reply.sentence(in: Self.promptPhrasebook)
		case .interrupted(let partial, _, _) where !partial.isEmpty:
			replyText = partial
		case .savedWork(let outcome, let saved):
			replyText = AthleteNotices.notice(for: outcome, saved: saved).canonicalSentence
		case .interrupted, .failed:
			return nil
		}
		return ConversationRow(
			ulid: settled.ulid, origin: settled.origin,
			account: claims.first { $0.attempt == settled.attempt }?.account ?? settled.account,
			message: ChatMessage(author: .coach, text: replyText))
	}
}

package struct ClaimedAttempt: Sendable, Equatable {
	package let hlc: HybridLogicalClock
	package let body: TurnClaimBody
	package var account: TrainingAccount = .unconnected

	package var attempt: AttemptID { body.attempt }
	package var process: ProcessID? { body.process }
}

package struct Fragment: Sendable, Equatable {
	package let ulid: ULID
	package let hlc: HybridLogicalClock
	package let civilDate: CivilDate
	package let timeZone: IANATimeZone
	package let index: Int
	package let draft: DraftID?
	package let text: String
	package let slash: SlashCommand?
	package var account: TrainingAccount = .unconnected
}

package struct SettledAttempt: Sendable, Equatable {
	package let ulid: ULID
	package let hlc: HybridLogicalClock
	package let attempt: AttemptID
	package let settlement: Settlement
	package var origin: DeviceID = DeviceID(rawValue: "unverified")
	package var account: TrainingAccount = .unconnected
}

extension Settlement {
	fileprivate func resolvingCalendarWrites(evidence: [CalendarWriteEvidence]) -> Settlement {
		guard !evidence.isEmpty else { return self }
		switch self {
		case .interrupted(let partial, let cause, let saved):
			return .interrupted(
				partial: partial, cause: cause, saved: saved.resolvingCalendarWrites(evidence))
		case .failed(let failure, let saved):
			return .failed(failure, saved: saved.resolvingCalendarWrites(evidence))
		case .savedWork(let outcome, let saved):
			let updated = saved.resolvingCalendarWrites(evidence)
			return .savedWork(outcome, saved: updated)
		case .replied:
			return self
		}
	}
}

extension WriteSummary {
	fileprivate func resolvingCalendarWrites(_ evidence: [CalendarWriteEvidence]) -> WriteSummary {
		WriteSummary(
			memorySections: memorySections, ledgerEvents: ledgerEvents, planSaves: planSaves,
			calendarWrites: evidence.filter(\.dispatched).count,
			unverifiedCalendarWrites: evidence.filter { $0.dispatched && !$0.applied }.count)
	}
}
