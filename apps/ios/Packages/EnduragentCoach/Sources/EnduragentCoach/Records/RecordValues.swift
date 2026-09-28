import Foundation

func encodeWindowReason(_ reason: WindowReason) -> String {
	switch reason {
	case .trim: "trim"
	case .compaction: "compaction"
	case .reset(.daily): "reset:daily"
	case .reset(.idle): "reset:idle"
	case .reset(.explicit(let id)): "reset:explicit:\(id.ulid.rawValue)"
	}
}

func decodeWindowReason(_ raw: String) throws -> WindowReason {
	switch raw {
	case "trim": return .trim
	case "compaction": return .compaction
	case "reset:daily": return .reset(.daily)
	case "reset:idle": return .reset(.idle)
	default:
		let prefix = "reset:explicit:"
		guard raw.hasPrefix(prefix) else {
			throw RecordDecodeFailure(reason: "window reason")
		}
		return .reset(.explicit(ResetID(ulid: try decodeULID(String(raw.dropFirst(prefix.count))))))
	}
}

func decodeChatID(_ raw: String) throws -> ChatID {
	guard let value = ChatID(rawValue: raw) else {
		throw RecordDecodeFailure(reason: "chatId")
	}
	return value
}

func decodeULID(_ raw: String) throws -> ULID {
	guard let value = ULID(rawValue: raw) else {
		throw RecordDecodeFailure(reason: "ulid")
	}
	return value
}

func decodeCivilDate(_ raw: String) throws -> CivilDate {
	guard let value = CivilDate(rawValue: raw) else {
		throw RecordDecodeFailure(reason: "civilDate")
	}
	return value
}

func decodeSlash(_ raw: String) throws -> SlashCommand {
	guard let value = SlashCommand(rawValue: raw) else {
		throw RecordDecodeFailure(reason: "slash")
	}
	return value
}
