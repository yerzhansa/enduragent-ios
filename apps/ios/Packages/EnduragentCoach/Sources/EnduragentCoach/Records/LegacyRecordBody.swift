import Foundation

public enum LegacyRecordBody: Sendable, Equatable {
	case userMessageV1(chatId: ChatID, athleteText: String, slash: SlashCommand?)
	case assistantMessage(AssistantMessageBody)
	case windowStartV1(chatId: ChatID, firstIncludedUlid: ULID)

	public var kind: LegacyKind {
		switch self {
		case .userMessageV1: .userMessage
		case .assistantMessage: .assistantMessage
		case .windowStartV1: .windowStart
		}
	}

	public var chatId: ChatID? {
		switch self {
		case .userMessageV1(let chatId, _, _): chatId
		case .assistantMessage(let body): body.chatId
		case .windowStartV1(let chatId, _): chatId
		}
	}
}

public struct AssistantMessageBody: Sendable, Equatable {
	public var chatId: ChatID
	public var text: String
	public var templateHash: String
	public var assembledHash: String
}
