import Foundation

enum SyncedPayload: Encodable {
	case userMessage(UserMessagePayload)
	case attemptQuestion(AttemptQuestionPayload)
	case turnSettled(TurnSettledPayload)
	case windowStart(WindowStartPayload)
	case compactionSummary(CompactionSummaryPayload)
	case memorySection(MemorySectionPayload)
	case dailyNote(DailyNotePayload)
	case ledgerEvent(LedgerEventPayload)
	case journal(JournalPayload)
	case provenance(ProvenancePayload)
	case coachReplyLanguage(CoachReplyLanguagePayload)
	case reviewOutcome(ReviewOutcomePayload)
	case sessionSettings(SessionSettingsPayload)
	case languagePreference(LanguagePreferencePayload)
	case trainingIdentityObserved
	case savedPlan(SavedPlanPayload)

	init(_ body: SyncedRecordBody) {
		switch body {
		case .attemptQuestion(let value):
			self = .attemptQuestion(AttemptQuestionPayload(value))
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
		case .reviewOutcome(let value):
			self = .reviewOutcome(ReviewOutcomePayload(value))
		case .sessionSettings(let value):
			self = .sessionSettings(SessionSettingsPayload(value))
		case .languagePreference(let value):
			self = .languagePreference(LanguagePreferencePayload(value))
		case .trainingIdentityObserved:
			self = .trainingIdentityObserved
		case .savedPlan(let value):
			self = .savedPlan(SavedPlanPayload(value))
		}
	}

	func encode(to encoder: Encoder) throws {
		switch self {
		case .userMessage(let payload): try payload.encode(to: encoder)
		case .attemptQuestion(let payload): try payload.encode(to: encoder)
		case .turnSettled(let payload): try payload.encode(to: encoder)
		case .windowStart(let payload): try payload.encode(to: encoder)
		case .compactionSummary(let payload): try payload.encode(to: encoder)
		case .memorySection(let payload): try payload.encode(to: encoder)
		case .dailyNote(let payload): try payload.encode(to: encoder)
		case .ledgerEvent(let payload): try payload.encode(to: encoder)
		case .journal(let payload): try payload.encode(to: encoder)
		case .provenance(let payload): try payload.encode(to: encoder)
		case .coachReplyLanguage(let payload): try payload.encode(to: encoder)
		case .reviewOutcome(let payload): try payload.encode(to: encoder)
		case .sessionSettings(let payload): try payload.encode(to: encoder)
		case .languagePreference(let payload): try payload.encode(to: encoder)
		case .trainingIdentityObserved:
			_ = encoder.container(keyedBy: IdentityObservationKey.self)
		case .savedPlan(let payload): try payload.encode(to: encoder)
		}
	}
}

enum DeviceLocalPayload: Encodable {
	case openRouterKeyRejected(RejectedOpenRouterKeyPayload)
	case providerConsent(ProviderConsentPayload)
	case turnClaim(TurnClaimPayload)
	case replyObserved(TurnAttemptPayload)
	case pendingSettlement(TurnSettledPayload)
	case flushPending(FlushPendingPayload)
	case flushSettled(FlushSettledPayload)
	case workoutReview(ReviewDocument)
	case reviewPreparing(TurnAttemptPayload)

	init(_ body: DeviceLocalRecordBody) {
		switch body {
		case .openRouterKeyRejected(let value):
			self = .openRouterKeyRejected(RejectedOpenRouterKeyPayload(value))
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
		case .workoutReview(let value):
			self = .workoutReview(ReviewDocument(value.review))
		case .reviewPreparing(let value):
			self = .reviewPreparing(
				TurnAttemptPayload(
					chatId: value.chatId.rawValue,
					turn: value.turn.ulid.rawValue,
					attempt: value.attempt.ulid.rawValue
				)
			)
		}
	}

	func encode(to encoder: Encoder) throws {
		switch self {
		case .openRouterKeyRejected(let payload): try payload.encode(to: encoder)
		case .providerConsent(let payload): try payload.encode(to: encoder)
		case .turnClaim(let payload): try payload.encode(to: encoder)
		case .replyObserved(let payload): try payload.encode(to: encoder)
		case .pendingSettlement(let payload): try payload.encode(to: encoder)
		case .flushPending(let payload): try payload.encode(to: encoder)
		case .flushSettled(let payload): try payload.encode(to: encoder)
		case .workoutReview(let payload): try payload.encode(to: encoder)
		case .reviewPreparing(let payload): try payload.encode(to: encoder)
		}
	}
}

private enum IdentityObservationKey: CodingKey {}
