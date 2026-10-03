import Foundation

enum SyncedPayload: Encodable {
	case userMessage(UserMessagePayload)
	case turnSettled(TurnSettledPayload)
	case windowStart(WindowStartPayload)
	case compactionSummary(CompactionSummaryPayload)
	case memorySection(MemorySectionPayload)
	case dailyNote(DailyNotePayload)
	case ledgerEvent(LedgerEventPayload)
	case journal(JournalPayload)
	case provenance(ProvenancePayload)
	case coachReplyLanguage(CoachReplyLanguagePayload)
	case planningDevice(PlanningDevicePayload)
	case reviewApplied(ReviewAppliedPayload)
	case reviewWrite(ReviewWritePayload)
	case reviewCancelledUnknown(ReviewCancelledUnknownPayload)
	case sessionSettings(SessionSettingsPayload)
	case languagePreference(LanguagePreferencePayload)
	case trainingIdentityObserved

	init(_ body: SyncedRecordBody) {
		switch body {
		case .userMessage(let value):
			self = .userMessage(
				UserMessagePayload(
					chatId: value.chatId.rawValue,
					turn: value.turn.ulid.rawValue,
					fragment: value.fragment,
					draft: value.draft.rawValue,
					athleteText: value.athleteText,
					slash: value.slash?.rawValue
				)
			)
		case .turnSettled(let value):
			self = .turnSettled(TurnSettledPayload(value))
		case .windowStart(let value):
			self = .windowStart(
				WindowStartPayload(
					chatId: value.chatId.rawValue,
					firstIncludedUlid: value.firstIncludedUlid.rawValue,
					reason: encodeWindowReason(value.reason),
					droppedMessageUlids: value.droppedMessageUlids?.map(\.rawValue),
					boundaryClock: value.boundaryClock.map(HybridLogicalClockPayload.init)
				)
			)
		case .compactionSummary(let value):
			self = .compactionSummary(
				CompactionSummaryPayload(chatId: value.chatId.rawValue, markdown: value.markdown))
		case .memorySection(let value):
			self = .memorySection(
				MemorySectionPayload(name: value.name.rawValue, content: value.content))
		case .dailyNote(let value):
			self = .dailyNote(DailyNotePayload(note: value.note))
		case .ledgerEvent(let value):
			self = .ledgerEvent(
				LedgerEventPayload(
					date: value.date.rawValue,
					kind: value.kind.rawValue,
					text: value.text,
					source: value.source.rawValue
				)
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
		case .reviewApplied(let value):
			self = .reviewApplied(
				ReviewAppliedPayload(value))
		case .reviewWrite(let value):
			self = .reviewWrite(ReviewWritePayload(value))
		case .reviewCancelledUnknown(let value):
			self = .reviewCancelledUnknown(ReviewCancelledUnknownPayload(value))
		case .sessionSettings(let value):
			self = .sessionSettings(SessionSettingsPayload(value))
		case .languagePreference(let value):
			self = .languagePreference(LanguagePreferencePayload(value))
		case .trainingIdentityObserved:
			self = .trainingIdentityObserved
		}
	}

	func encode(to encoder: Encoder) throws {
		switch self {
		case .userMessage(let payload): try payload.encode(to: encoder)
		case .turnSettled(let payload): try payload.encode(to: encoder)
		case .windowStart(let payload): try payload.encode(to: encoder)
		case .compactionSummary(let payload): try payload.encode(to: encoder)
		case .memorySection(let payload): try payload.encode(to: encoder)
		case .dailyNote(let payload): try payload.encode(to: encoder)
		case .ledgerEvent(let payload): try payload.encode(to: encoder)
		case .journal(let payload): try payload.encode(to: encoder)
		case .provenance(let payload): try payload.encode(to: encoder)
		case .coachReplyLanguage(let payload): try payload.encode(to: encoder)
		case .planningDevice(let payload): try payload.encode(to: encoder)
		case .reviewApplied(let payload): try payload.encode(to: encoder)
		case .reviewWrite(let payload): try payload.encode(to: encoder)
		case .reviewCancelledUnknown(let payload): try payload.encode(to: encoder)
		case .sessionSettings(let payload): try payload.encode(to: encoder)
		case .languagePreference(let payload): try payload.encode(to: encoder)
		case .trainingIdentityObserved:
			_ = encoder.container(keyedBy: IdentityObservationKey.self)
		}
	}
}

enum DeviceLocalPayload: Encodable {
	case providerConsent(ProviderConsentPayload)
	case turnClaim(TurnClaimPayload)
	case replyObserved(TurnAttemptPayload)
	case pendingSettlement(TurnSettledPayload)
	case pendingProposal(ProposalPayload)
	case proposalCleared(ProposalClearedPayload)
	case flushPending(FlushPendingPayload)
	case flushSettled(FlushSettledPayload)
	case planningCommand(PlanningCommandPayload)
	case planRevision(PlanRevisionPayload)
	case mirrorJob(MirrorJobPayload)
	case workoutMatch(WorkoutMatchPayload)
	case workoutDrift(WorkoutDriftPayload)

	init(_ body: DeviceLocalRecordBody) {
		switch body {
		case .providerConsent(let value): self = .providerConsent(ProviderConsentPayload(value))
		case .turnClaim(let value):
			self = .turnClaim(
				TurnClaimPayload(
					chatId: value.chatId.rawValue,
					turn: value.turn.ulid.rawValue,
					attempt: value.attempt.ulid.rawValue,
					process: value.process?.ulid.rawValue,
					lease: value.lease.rawValue
				)
			)
		case .replyObserved(let value):
			self = .replyObserved(
				TurnAttemptPayload(
					chatId: value.chatId.rawValue,
					turn: value.turn.ulid.rawValue,
					attempt: value.attempt.ulid.rawValue
				)
			)
		case .pendingSettlement(let value):
			self = .pendingSettlement(TurnSettledPayload(value))
		case .pendingProposal(let value):
			self = .pendingProposal(
				ProposalPayload(
					writeID: value.writeID?.rawValue,
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
					messageUlids: value.messageUlids.map(\.rawValue),
					process: value.process?.ulid.rawValue
				)
			)
		case .flushSettled(let value):
			self = .flushSettled(FlushSettledPayload(value))
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

	func encode(to encoder: Encoder) throws {
		switch self {
		case .providerConsent(let payload): try payload.encode(to: encoder)
		case .turnClaim(let payload): try payload.encode(to: encoder)
		case .replyObserved(let payload): try payload.encode(to: encoder)
		case .pendingSettlement(let payload): try payload.encode(to: encoder)
		case .pendingProposal(let payload): try payload.encode(to: encoder)
		case .proposalCleared(let payload): try payload.encode(to: encoder)
		case .flushPending(let payload): try payload.encode(to: encoder)
		case .flushSettled(let payload): try payload.encode(to: encoder)
		case .planningCommand(let payload): try payload.encode(to: encoder)
		case .planRevision(let payload): try payload.encode(to: encoder)
		case .mirrorJob(let payload): try payload.encode(to: encoder)
		case .workoutMatch(let payload): try payload.encode(to: encoder)
		case .workoutDrift(let payload): try payload.encode(to: encoder)
		}
	}
}

private enum IdentityObservationKey: CodingKey {}
