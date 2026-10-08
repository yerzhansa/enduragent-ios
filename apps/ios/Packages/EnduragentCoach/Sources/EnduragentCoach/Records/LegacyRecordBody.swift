import Foundation

package enum LegacyRecordBody: Sendable, Equatable {
	case userMessageV1(chatId: ChatID, athleteText: String, slash: SlashCommand?)
	case assistantMessage(AssistantMessageBody)
	case windowStartV1(chatId: ChatID, firstIncludedUlid: ULID)

	package var kind: LegacyKind {
		switch self {
		case .userMessageV1: .userMessage
		case .assistantMessage: .assistantMessage
		case .windowStartV1: .windowStart
		}
	}

	package var chatId: ChatID? {
		switch self {
		case .userMessageV1(let chatId, _, _): chatId
		case .assistantMessage(let body): body.chatId
		case .windowStartV1(let chatId, _): chatId
		}
	}
}

package struct AssistantMessageBody: Sendable, Equatable {
	package var chatId: ChatID
	package var text: String
	package var templateHash: String
	package var assembledHash: String
}
