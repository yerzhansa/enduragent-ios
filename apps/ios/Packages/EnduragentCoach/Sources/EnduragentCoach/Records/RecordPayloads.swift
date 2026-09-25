import Foundation

struct UserMessagePayload: Codable {
	var chatId: String
	var athleteText: String
	var timedText: String
	var slash: String?
}

struct AssistantMessagePayload: Codable {
	var chatId: String
	var text: String
	var templateHash: String
	var assembledHash: String
}

struct WindowStartPayload: Codable {
	var chatId: String
	var firstIncludedUlid: String
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

struct DurationPayload: Codable {
	var value: Double
	var unit: String
}

struct PowerPayload: Codable {
	var kind: String
	var value: Double?
	var low: Double?
	var high: Double?
}

struct CadencePayload: Codable {
	var value: Int?
	var low: Int?
	var high: Int?
}

struct SimpleStepPayload: Codable {
	var type: String
	var duration: DurationPayload
	var power: PowerPayload?
	var cadence: CadencePayload?
	var label: String?
}

struct SetStepPayload: Codable {
	var repeatCount: Int
	var interval: SimpleStepPayload
	var recovery: SimpleStepPayload
}

enum StepPayload: Codable {
	case simple(SimpleStepPayload)
	case set(SetStepPayload)
}

struct WorkoutPayload: Codable {
	var name: String
	var steps: [StepPayload]
}

enum GatedToolInputPayload: Codable {
	case createWorkout(date: String, workout: WorkoutPayload)
	case createStrengthWorkout(date: String, name: String, description: String)
	case deleteWorkout(eventId: Int)
	case updateWorkout(eventId: Int, date: String?, name: String?, description: String?)
	case planSave(name: String, primaryGoal: String?, totalWeeks: Int?, status: String?)
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

enum BodyEnvelope: Codable {
	case userMessage(UserMessagePayload)
	case assistantMessage(AssistantMessagePayload)
	case windowStart(WindowStartPayload)
	case compactionSummary(CompactionSummaryPayload)
	case memorySection(MemorySectionPayload)
	case dailyNote(DailyNotePayload)
	case ledgerEvent(LedgerEventPayload)
	case journal(JournalPayload)
	case provenance(ProvenancePayload)
	case pendingProposal(ProposalPayload)
	case proposalCleared(ProposalClearedPayload)
	case flushPending(FlushPendingPayload)
	case coachReplyLanguage(CoachReplyLanguagePayload)
	case planningDevice(PlanningDevicePayload)
	case planningCommand(PlanningCommandPayload)
	case planRevision(PlanRevisionPayload)
	case mirrorJob(MirrorJobPayload)
	case workoutMatch(WorkoutMatchPayload)
	case workoutDrift(WorkoutDriftPayload)
}
