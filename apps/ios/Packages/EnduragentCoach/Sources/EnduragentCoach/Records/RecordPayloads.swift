import Foundation

struct UserMessageV1Payload: Codable {
	var chatId: String
	var athleteText: String
	var slash: String?
}

struct UserMessagePayload: Codable {
	var chatId: String
	var turn: String
	var fragment: Int
	var draft: UUID
	var athleteText: String
	var slash: String?
}

struct TurnSettledPayload: Codable {
	var chatId: String
	var turn: String
	var attempt: String
	var settlement: SettlementPayload
}

struct SettlementPayload: Codable {
	var kind: String
	var modelText: String?
	var templateHash: String?
	var assembledHash: String?
	var failure: FailurePayload?
	var partial: String?
	var cause: String?
	var saved: WriteSummaryPayload?

	init(_ settlement: Settlement) {
		switch settlement {
		case .replied(let text, let lineage):
			kind = "replied"
			switch text {
			case .model(let modelText):
				self.modelText = modelText
			}
			templateHash = lineage?.templateHash
			assembledHash = lineage?.assembledHash
		case .failed(let failure, let saved):
			kind = "failed"
			self.failure = FailurePayload(failure)
			self.saved = WriteSummaryPayload(saved)
		case .interrupted(let partial, let cause, let saved):
			kind = "interrupted"
			self.partial = partial
			self.cause = cause.rawValue
			self.saved = WriteSummaryPayload(saved)
		}
	}

	func settlement() throws -> Settlement {
		switch kind {
		case "replied":
			guard let modelText else {
				throw RecordDecodeFailure(reason: "settlement")
			}
			let lineage: ReplyLineage?
			if let templateHash, let assembledHash {
				lineage = ReplyLineage(templateHash: templateHash, assembledHash: assembledHash)
			} else {
				lineage = nil
			}
			return .replied(.model(modelText), lineage: lineage)
		case "failed":
			guard let failure, let saved else {
				throw RecordDecodeFailure(reason: "settlement")
			}
			return .failed(try failure.failure(), saved: saved.summary)
		case "interrupted":
			guard let partial, let cause = cause.flatMap(InterruptionCause.init(rawValue:)),
				let saved
			else {
				throw RecordDecodeFailure(reason: "settlement")
			}
			return .interrupted(partial: partial, cause: cause, saved: saved.summary)
		default:
			throw RecordDecodeFailure(reason: "settlement")
		}
	}
}

struct FailurePayload: Codable {
	var domain: String
	var code: String
	var detail: String?

	init(_ failure: CoachFailure) {
		switch failure {
		case .model(.providerDown(let trouble)):
			domain = "model"
			code = "providerDown"
			detail = trouble.rawValue
		case .model(.contextOverflow):
			domain = "model"
			code = "contextOverflow"
		case .model(.generationFailed(let fault)):
			domain = "model"
			code = "generationFailed"
			detail = fault.rawValue
		case .model(.budgetExhausted(let kind)):
			domain = "model"
			code = "budgetExhausted"
			detail = kind.rawValue
		case .local(let local):
			domain = "local"
			code = local.rawValue
		}
	}

	func failure() throws -> CoachFailure {
		switch (domain, code) {
		case ("model", "providerDown"):
			guard let trouble = detail.flatMap(ProviderTrouble.init(rawValue:)) else {
				throw RecordDecodeFailure(reason: "failure")
			}
			return .model(.providerDown(trouble))
		case ("model", "contextOverflow"):
			return .model(.contextOverflow)
		case ("model", "generationFailed"):
			guard let fault = detail.flatMap(GenerationFault.init(rawValue:)) else {
				throw RecordDecodeFailure(reason: "failure")
			}
			return .model(.generationFailed(fault))
		case ("model", "budgetExhausted"):
			guard let kind = detail.flatMap(TurnBudgetExceeded.Kind.init(rawValue:)) else {
				throw RecordDecodeFailure(reason: "failure")
			}
			return .model(.budgetExhausted(kind))
		case ("local", _):
			guard let local = LocalFailure(rawValue: code) else {
				throw RecordDecodeFailure(reason: "failure")
			}
			return .local(local)
		default:
			throw RecordDecodeFailure(reason: "failure")
		}
	}
}

struct WriteSummaryPayload: Codable {
	var memorySections: Int
	var ledgerEvents: Int
	var planSaves: Int
	var calendarWrites: Int

	init(_ summary: WriteSummary) {
		memorySections = summary.memorySections
		ledgerEvents = summary.ledgerEvents
		planSaves = summary.planSaves
		calendarWrites = summary.calendarWrites
	}

	var summary: WriteSummary {
		WriteSummary(
			memorySections: memorySections,
			ledgerEvents: ledgerEvents,
			planSaves: planSaves,
			calendarWrites: calendarWrites
		)
	}
}

struct TurnClaimPayload: Codable {
	var chatId: String
	var turn: String
	var attempt: String
}

struct AssistantMessagePayload: Codable {
	var chatId: String
	var text: String
	var templateHash: String
	var assembledHash: String
}

struct WindowStartV1Payload: Codable {
	var chatId: String
	var firstIncludedUlid: String
}

struct WindowStartPayload: Codable {
	var chatId: String
	var firstIncludedUlid: String
	var reason: String
}

struct CompactionSummaryPayload: Codable {
	var chatId: String
	var markdown: String
}

struct MemorySectionPayload: Codable {
	var name: String
	var content: String
}

struct DailyNotePayload: Codable {
	var note: String
}

struct LedgerEventPayload: Codable {
	var date: String?
	var kind: String
	var text: String
	var source: String
}

struct JournalPayload: Codable {
	var op: String
	var preview: String
}

struct ProvenancePayload: Codable {
	var key: String
	var garmin: Bool
	var nonGarmin: Bool
	var unknown: Bool
	var contentSha256: String
}

struct ProposalPayload: Codable {
	var chatId: String
	var nonce: UUID
	var tool: String
	var toolInput: GatedToolInputPayload
	var summary: String
	var description: String
	var expiresAt: TimeInterval
}

struct ProposalClearedPayload: Codable {
	var chatId: String
	var nonce: UUID
	var reason: String
}

struct FlushPendingPayload: Codable {
	var chatId: String
	var trigger: String
	var messageUlids: [String]
}

struct CoachReplyLanguagePayload: Codable {
	var tag: String?
}

struct PlanningDevicePayload: Codable {
	var planningDeviceId: String
	var planUlid: String
	var activatedAt: TimeInterval
}

struct JSONValuePayload: Codable {
	var value: JSONValue

	init(_ value: JSONValue) {
		self.value = value
	}

	init(from decoder: Decoder) throws {
		let container = try decoder.singleValueContainer()
		if container.decodeNil() {
			value = .null
			return
		}
		if let flag = try? container.decode(Bool.self) {
			value = .bool(flag)
			return
		}
		if let number = try? container.decode(Double.self) {
			value = .number(number)
			return
		}
		if let string = try? container.decode(String.self) {
			value = .string(string)
			return
		}
		if let items = try? container.decode([JSONValuePayload].self) {
			value = .array(items.map(\.value))
			return
		}
		if let fields = try? container.decode([String: JSONValuePayload].self) {
			value = .object(fields.mapValues(\.value))
			return
		}
		throw RecordDecodeFailure(reason: "json")
	}

	func encode(to encoder: Encoder) throws {
		var container = encoder.singleValueContainer()
		switch value {
		case .null:
			try container.encodeNil()
		case .bool(let flag):
			try container.encode(flag)
		case .number(let number):
			try container.encode(number)
		case .string(let string):
			try container.encode(string)
		case .array(let items):
			try container.encode(items.map(JSONValuePayload.init))
		case .object(let fields):
			try container.encode(fields.mapValues(JSONValuePayload.init))
		}
	}
}

struct PlanningCommandPayload: Codable {
	var commandName: String
	var commandId: String
	var requestDigest: String
	var status: String
	var result: JSONValuePayload?
}

struct PlanRevisionPayload: Codable {
	var planUlid: String
	var version: Int
	var status: String
	var snapshot: JSONValuePayload
}

struct MirrorJobPayload: Codable {
	var planUlid: String
	var kind: String
	var windowStart: Int
	var windowEnd: Int
	var failureCount: Int
}

struct WorkoutMatchPayload: Codable {
	var planWorkoutId: String
	var activityId: String
	var decision: String
}

struct WorkoutDriftPayload: Codable {
	var planWorkoutId: String
	var askedAt: TimeInterval
}

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
