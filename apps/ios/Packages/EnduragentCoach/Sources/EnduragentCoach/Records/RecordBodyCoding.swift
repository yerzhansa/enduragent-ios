import Foundation

func encodeRecordBody(_ body: RecordBody) throws -> Data {
	let encoder = JSONEncoder()
	encoder.outputFormatting = [.sortedKeys]
	return try encoder.encode(BodyEnvelope(body))
}

func decodeRecordBody(_ data: Data) throws -> RecordBody {
	try JSONDecoder().decode(BodyEnvelope.self, from: data).recordBody()
}

extension BodyEnvelope {
	init(_ body: RecordBody) {
		switch body {
		case .userMessage(let value):
			self = .userMessage(
				UserMessagePayload(
					chatId: value.chatId.rawValue,
					athleteText: value.athleteText,
					timedText: value.timedText,
					slash: value.slash?.rawValue
				)
			)
		case .assistantMessage(let value):
			self = .assistantMessage(
				AssistantMessagePayload(
					chatId: value.chatId.rawValue,
					text: value.text,
					templateHash: value.templateHash,
					assembledHash: value.assembledHash
				)
			)
		case .windowStart(let value):
			self = .windowStart(
				WindowStartPayload(
					chatId: value.chatId.rawValue,
					firstIncludedUlid: value.firstIncludedUlid.rawValue)
			)
		case .compactionSummary(let value):
			self = .compactionSummary(
				CompactionSummaryPayload(chatId: value.chatId.rawValue, markdown: value.markdown)
			)
		case .memorySection(let value):
			self = .memorySection(
				MemorySectionPayload(name: value.name.rawValue, content: value.content))
		case .dailyNote(let value):
			self = .dailyNote(DailyNotePayload(note: value.note))
		case .ledgerEvent(let value):
			self = .ledgerEvent(
				LedgerEventPayload(
					kind: value.kind.rawValue, text: value.text, source: value.source.rawValue)
			)
		case .journal(let value):
			self = .journal(JournalPayload(op: value.op.rawValue, preview: value.preview))
		case .provenance(let value):
			self = .provenance(
				ProvenancePayload(
					key: value.key,
					garmin: value.garmin,
					nonGarmin: value.nonGarmin,
					unknown: value.unknown,
					contentSha256: value.contentSha256
				)
			)
		case .pendingProposal(let value):
			self = .pendingProposal(
				ProposalPayload(
					chatId: value.chatId.rawValue,
					nonce: value.nonce.rawValue,
					tool: value.tool.rawValue,
					toolInput: GatedToolInputPayload(value.toolInput),
					summary: value.summary,
					description: value.description,
					expiresAt: value.expiresAt.timeIntervalSince1970
				)
			)
		case .proposalCleared(let value):
			self = .proposalCleared(
				ProposalClearedPayload(
					chatId: value.chatId.rawValue,
					nonce: value.nonce.rawValue,
					reason: value.reason.rawValue
				)
			)
		case .flushPending(let value):
			self = .flushPending(
				FlushPendingPayload(
					chatId: value.chatId.rawValue,
					trigger: value.trigger.rawValue,
					messageUlids: value.messageUlids.map(\.rawValue)
				)
			)
		case .coachReplyLanguage(let value):
			self = .coachReplyLanguage(CoachReplyLanguagePayload(tag: value.tag?.rawValue))
		case .planningDevice(let value):
			self = .planningDevice(
				PlanningDevicePayload(
					planningDeviceId: value.planningDeviceId.rawValue,
					planUlid: value.planUlid.rawValue,
					activatedAt: value.activatedAt.timeIntervalSince1970
				)
			)
		case .planningCommand(let value):
			self = .planningCommand(
				PlanningCommandPayload(
					commandName: value.commandName.rawValue,
					commandId: value.commandId,
					requestDigest: value.requestDigest,
					status: value.status.rawValue,
					result: value.result.map(JSONValuePayload.init)
				)
			)
		case .planRevision(let value):
			self = .planRevision(
				PlanRevisionPayload(
					planUlid: value.planUlid.rawValue,
					version: value.version,
					status: value.status.rawValue,
					snapshot: JSONValuePayload(value.snapshot)
				)
			)
		case .mirrorJob(let value):
			self = .mirrorJob(
				MirrorJobPayload(
					planUlid: value.planUlid.rawValue,
					kind: value.kind.rawValue,
					windowStart: value.windowStart.rawValue,
					windowEnd: value.windowEnd.rawValue,
					failureCount: value.failureCount
				)
			)
		case .workoutMatch(let value):
			self = .workoutMatch(
				WorkoutMatchPayload(
					planWorkoutId: value.planWorkoutId.rawValue,
					activityId: value.activityId,
					decision: value.decision.rawValue
				)
			)
		case .workoutDrift(let value):
			self = .workoutDrift(
				WorkoutDriftPayload(
					planWorkoutId: value.planWorkoutId.rawValue,
					askedAt: value.askedAt.timeIntervalSince1970
				)
			)
		}
	}

	func recordBody() throws -> RecordBody {
		switch self {
		case .userMessage(let payload):
			return .userMessage(
				UserMessageBody(
					chatId: try decodeChatID(payload.chatId),
					athleteText: payload.athleteText,
					timedText: payload.timedText,
					slash: try payload.slash.map(decodeSlash)
				)
			)
		case .assistantMessage(let payload):
			return .assistantMessage(
				AssistantMessageBody(
					chatId: try decodeChatID(payload.chatId),
					text: payload.text,
					templateHash: payload.templateHash,
					assembledHash: payload.assembledHash
				)
			)
		case .windowStart(let payload):
			return .windowStart(
				WindowStartBody(
					chatId: try decodeChatID(payload.chatId),
					firstIncludedUlid: try decodeULID(payload.firstIncludedUlid))
			)
		case .compactionSummary(let payload):
			return .compactionSummary(
				CompactionSummaryBody(
					chatId: try decodeChatID(payload.chatId), markdown: payload.markdown)
			)
		case .memorySection(let payload):
			return .memorySection(
				MemorySectionBody(
					name: SectionName(rawValue: payload.name), content: payload.content)
			)
		case .dailyNote(let payload):
			return .dailyNote(DailyNoteBody(note: payload.note))
		case .ledgerEvent(let payload):
			guard let kind = LedgerKind(rawValue: payload.kind),
				let source = LedgerSource(rawValue: payload.source)
			else {
				throw RecordDecodeFailure(reason: "ledger")
			}
			return .ledgerEvent(LedgerEventBody(kind: kind, text: payload.text, source: source))
		case .journal(let payload):
			guard let op = JournalOp(rawValue: payload.op) else {
				throw RecordDecodeFailure(reason: "journal")
			}
			return .journal(JournalBody(op: op, preview: payload.preview))
		case .provenance(let payload):
			return .provenance(
				ProvenanceBody(
					key: payload.key,
					garmin: payload.garmin,
					nonGarmin: payload.nonGarmin,
					unknown: payload.unknown,
					contentSha256: payload.contentSha256
				)
			)
		case .pendingProposal(let payload):
			guard let tool = GatedToolName(rawValue: payload.tool) else {
				throw RecordDecodeFailure(reason: "tool")
			}
			return .pendingProposal(
				ProposalBody(
					chatId: try decodeChatID(payload.chatId),
					nonce: Nonce(rawValue: payload.nonce),
					tool: tool,
					toolInput: try payload.toolInput.gatedToolInput(),
					summary: payload.summary,
					description: payload.description,
					expiresAt: Date(timeIntervalSince1970: payload.expiresAt)
				)
			)
		case .proposalCleared(let payload):
			guard let reason = ProposalClearReason(rawValue: payload.reason) else {
				throw RecordDecodeFailure(reason: "clear")
			}
			return .proposalCleared(
				ProposalClearedBody(
					chatId: try decodeChatID(payload.chatId),
					nonce: Nonce(rawValue: payload.nonce),
					reason: reason
				)
			)
		case .flushPending(let payload):
			guard let trigger = FlushTrigger(rawValue: payload.trigger) else {
				throw RecordDecodeFailure(reason: "flush")
			}
			return .flushPending(
				FlushPendingBody(
					chatId: try decodeChatID(payload.chatId),
					trigger: trigger,
					messageUlids: try payload.messageUlids.map(decodeULID)
				)
			)
		case .coachReplyLanguage(let payload):
			let tag: LanguageTag?
			if let raw = payload.tag {
				guard let parsed = LanguageTag(rawValue: raw) else {
					throw RecordDecodeFailure(reason: "language")
				}
				tag = parsed
			} else {
				tag = nil
			}
			return .coachReplyLanguage(CoachReplyLanguageBody(tag: tag))
		case .planningDevice(let payload):
			return .planningDevice(
				PlanningDeviceBody(
					planningDeviceId: DeviceID(rawValue: payload.planningDeviceId),
					planUlid: try decodeULID(payload.planUlid),
					activatedAt: Date(timeIntervalSince1970: payload.activatedAt)
				)
			)
		case .planningCommand(let payload):
			guard let name = PlanningCommandName(rawValue: payload.commandName),
				let status = PlanningCommandStatus(rawValue: payload.status)
			else {
				throw RecordDecodeFailure(reason: "planningCommand")
			}
			return .planningCommand(
				PlanningCommandBody(
					commandName: name,
					commandId: payload.commandId,
					requestDigest: payload.requestDigest,
					status: status,
					result: payload.result?.value
				)
			)
		case .planRevision(let payload):
			guard let status = PlanStatus(rawValue: payload.status) else {
				throw RecordDecodeFailure(reason: "planStatus")
			}
			return .planRevision(
				PlanRevisionBody(
					planUlid: try decodeULID(payload.planUlid),
					version: payload.version,
					status: status,
					snapshot: payload.snapshot.value
				)
			)
		case .mirrorJob(let payload):
			guard let kind = MirrorJobKind(rawValue: payload.kind),
				let windowStart = DateKey(rawValue: payload.windowStart),
				let windowEnd = DateKey(rawValue: payload.windowEnd)
			else {
				throw RecordDecodeFailure(reason: "mirror")
			}
			return .mirrorJob(
				MirrorJobBody(
					planUlid: try decodeULID(payload.planUlid),
					kind: kind,
					windowStart: windowStart,
					windowEnd: windowEnd,
					failureCount: payload.failureCount
				)
			)
		case .workoutMatch(let payload):
			guard let decision = MatchDecision(rawValue: payload.decision) else {
				throw RecordDecodeFailure(reason: "match")
			}
			return .workoutMatch(
				WorkoutMatchBody(
					planWorkoutId: try decodeULID(payload.planWorkoutId),
					activityId: payload.activityId,
					decision: decision
				)
			)
		case .workoutDrift(let payload):
			return .workoutDrift(
				WorkoutDriftBody(
					planWorkoutId: try decodeULID(payload.planWorkoutId),
					askedAt: Date(timeIntervalSince1970: payload.askedAt)
				)
			)
		}
	}
}
