import Foundation

package struct PendingProposal: Sendable, Equatable {
	package var chatId: ChatID
	package var nonce: Nonce
	package var summary: String
	package var description: String
	package var expiresAt: Date
	package var account: TrainingAccount
}

public enum GatedToolInput: Sendable, Equatable {
	case createWorkout(date: CivilDate, workout: IntervalsWorkoutInput)
	case createStrengthWorkout(date: CivilDate, name: String, description: String)
	case deleteWorkout(eventId: EventID)
	case updateWorkout(UpdateWorkoutInput)
	case planSave(PlanHeadline)
}

public struct UpdateWorkoutInput: Sendable, Equatable {
	public var eventId: EventID
	public var date: CivilDate?
	public var name: String?
	public var description: String?
}

package struct LiveProposal: Sendable, Equatable {
	package let cause: RecordCause
	package let body: ProposalBody
	package let account: TrainingAccount
	package let ulid: ULID
}

package enum ProposalPolicy {
	package static let ttlSeconds: TimeInterval = 10 * 60

	package static func propose(
		chatId: ChatID,
		tool: GatedToolName,
		input: GatedToolInput,
		summary: String,
		description: String,
		now: Date,
		ledger: Ledger,
		stamp: OperationStamp
	) async throws -> PendingProposal {
		let records = try await ledger.read(proposalQuery(chatId)).records
		var bodies: [DeviceLocalRecordBody] = []
		if let live = UnionMerge.pendingProposal(records, chatId: chatId, now: now) {
			bodies.append(
				.proposalCleared(
					ProposalClearedBody(chatId: chatId, nonce: live.nonce, reason: .replaced)))
		}
		let nonce = Nonce()
		let expiresAt = now.addingTimeInterval(ttlSeconds)
		let body = ProposalBody(
			chatId: chatId,
			nonce: nonce,
			tool: tool,
			toolInput: input,
			summary: summary,
			description: description,
			expiresAt: expiresAt
		)
		bodies.append(.pendingProposal(body))
		_ = try await ledger.commit(local: bodies, stamp: stamp)
		return PendingProposal(
			chatId: chatId,
			nonce: nonce,
			summary: summary,
			description: description,
			expiresAt: expiresAt,
			account: stamp.binding.account
		)
	}

	package static func live(chatId: ChatID, ledger: Ledger, now: Date)
		async throws(LedgerFailure) -> LiveProposal?
	{
		let records = try await ledger.read(proposalQuery(chatId)).records
		return UnionMerge.pendingProposalRecord(records, chatId: chatId, now: now)
	}

	package static func clear(
		_ live: LiveProposal, reason: ProposalClearReason, ledger: Ledger, stamp: OperationStamp
	) async throws(LedgerFailure) {
		_ = try await ledger.commit(
			local: [
				.proposalCleared(
					ProposalClearedBody(
						chatId: live.body.chatId, nonce: live.body.nonce, reason: reason))
			],
			stamp: stamp
		)
	}

	package static func summary(for input: GatedToolInput) -> String {
		ReviewSummary(input).sentence(in: LanguageTag.en.phrasebook)
	}

	package static func proposalQuery(_ chatId: ChatID) -> RecordQuery {
		RecordQuery(scope: .deviceLocal([.pendingProposal, .proposalCleared]), chatId: chatId)
	}
}
