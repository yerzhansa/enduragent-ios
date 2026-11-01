import Foundation

package enum LegacyRecordBody: Sendable, Equatable {
	case userMessageV1(chatId: ChatID, athleteText: String, slash: SlashCommand?)
	case assistantMessage(AssistantMessageBody)
	case windowStartV1(chatId: ChatID, firstIncludedUlid: ULID)
	case pendingProposal(LegacyProposalBody)
	case proposalCleared(chatId: ChatID, nonce: Nonce)
	case reviewWrite(ReviewWriteBody)
	case reviewCancelledUnknown(ReviewCancelledUnknownBody)
	case reviewApplied(ReviewAppliedBody)
	case planningDevice(PlanningDeviceBody)

	package var kind: LegacyKind {
		switch self {
		case .userMessageV1: .userMessage
		case .assistantMessage: .assistantMessage
		case .windowStartV1: .windowStart
		case .pendingProposal: .pendingProposal
		case .proposalCleared: .proposalCleared
		case .reviewWrite: .reviewWrite
		case .reviewCancelledUnknown: .reviewCancelledUnknown
		case .reviewApplied: .reviewApplied
		case .planningDevice: .planningDevice
		}
	}

	package var chatId: ChatID? {
		switch self {
		case .userMessageV1(let chatId, _, _): chatId
		case .assistantMessage(let body): body.chatId
		case .windowStartV1(let chatId, _): chatId
		case .pendingProposal(let body): body.chatId
		case .proposalCleared(let chatId, _): chatId
		case .reviewWrite(let body): body.chatId
		case .reviewCancelledUnknown(let body): body.chatId
		case .reviewApplied(let body): body.chatId
		case .planningDevice: nil
		}
	}
}

package struct AssistantMessageBody: Sendable, Equatable {
	package var chatId: ChatID
	package var text: String
	package var templateHash: String
	package var assembledHash: String
}
