import Foundation

enum RecordCodec {
	static let currentBodyVersion = 3

	static func encode(_ body: RecordBody) throws -> (version: Int, data: Data) {
		let encoder = JSONEncoder()
		encoder.outputFormatting = [.sortedKeys]
		let data: Data
		let version: Int
		switch body {
		case .synced(let synced):
			data = try encoder.encode(SyncedPayload(synced))
			if case .windowStart(let window) = synced, window.boundaryClock != nil {
				version = 3
			} else {
				version = 2
			}
		case .deviceLocal(let local):
			data = try encoder.encode(DeviceLocalPayload(local))
			version = 2
		case .legacy(let legacy):
			throw RecordDecodeFailure(reason: "legacy kind \(legacy.kind.rawValue) is read-only")
		}
		return (version, data)
	}

	static func decode(kind: String, version: Int, data: Data, civilDate: CivilDate, ulid: String)
		-> Result<RecordBody, SkippedRow>
	{
		if version > currentBodyVersion {
			return .failure(.newerVersion(kind: kind, version: version, ulid: ulid))
		}
		do {
			if let synced = SyncedKind(rawValue: kind) {
				if version == 1, let legacy = try legacyBody(synced, data: data) {
					return .success(.legacy(legacy))
				}
				return .success(
					.synced(
						try syncedBody(synced, version: version, data: data, civilDate: civilDate)))
			}
			if let local = DeviceLocalKind(rawValue: kind) {
				return .success(
					.deviceLocal(try deviceLocalBody(local, version: version, data: data)))
			}
			if let legacy = LegacyKind(rawValue: kind) {
				guard version == 1, let body = try legacyBody(legacy, data: data) else {
					return .failure(.newerVersion(kind: kind, version: version, ulid: ulid))
				}
				return .success(.legacy(body))
			}
			return .failure(.newerKind(kind: kind, ulid: ulid))
		} catch {
			return .failure(.malformed(kind: kind, ulid: ulid))
		}
	}

	static func payload<Payload: Decodable>(
		_ type: Payload.Type, version: Int, kind: String, data: Data
	) throws -> Payload {
		let decoder = JSONDecoder()
		if version == 1 {
			let wrapped = try decoder.decode([String: [String: Payload]].self, from: data)
			guard let inner = wrapped[kind]?["_0"] else {
				throw RecordDecodeFailure(reason: "v1 envelope")
			}
			return inner
		}
		return try decoder.decode(Payload.self, from: data)
	}

	private static func legacyBody(_ kind: SyncedKind, data: Data) throws -> LegacyRecordBody? {
		switch kind {
		case .userMessage:
			return try legacyBody(LegacyKind.userMessage, data: data)
		case .windowStart:
			return try legacyBody(LegacyKind.windowStart, data: data)
		default:
			return nil
		}
	}

	private static func legacyBody(_ kind: LegacyKind, data: Data) throws -> LegacyRecordBody? {
		switch kind {
		case .userMessage:
			let payload = try payload(
				UserMessageV1Payload.self, version: 1, kind: kind.rawValue, data: data)
			return .userMessageV1(
				chatId: try decodeChatID(payload.chatId),
				athleteText: payload.athleteText,
				slash: try payload.slash.map(decodeSlash)
			)
		case .assistantMessage:
			let payload = try payload(
				AssistantMessagePayload.self, version: 1, kind: kind.rawValue, data: data)
			return .assistantMessage(
				AssistantMessageBody(
					chatId: try decodeChatID(payload.chatId),
					text: payload.text,
					templateHash: payload.templateHash,
					assembledHash: payload.assembledHash
				)
			)
		case .windowStart:
			let payload = try payload(
				WindowStartV1Payload.self, version: 1, kind: kind.rawValue, data: data)
			return .windowStartV1(
				chatId: try decodeChatID(payload.chatId),
				firstIncludedUlid: try decodeULID(payload.firstIncludedUlid)
			)
		}
	}

	private static func syncedBody(
		_ kind: SyncedKind, version: Int, data: Data, civilDate: CivilDate
	) throws -> SyncedRecordBody {
		let name = kind.rawValue
		switch kind {
		case .userMessage:
			let payload = try payload(
				UserMessagePayload.self, version: version, kind: name, data: data)
			return .userMessage(
				UserMessageBody(
					chatId: try decodeChatID(payload.chatId),
					turn: TurnID(ulid: try decodeULID(payload.turn)),
					fragment: payload.fragment,
					draft: DraftID(rawValue: payload.draft),
					athleteText: payload.athleteText,
					slash: try payload.slash.map(decodeSlash)
				)
			)
		case .turnSettled:
			return .turnSettled(
				try payload(TurnSettledPayload.self, version: version, kind: name, data: data)
					.body())
		case .windowStart:
			let payload = try payload(
				WindowStartPayload.self, version: version, kind: name, data: data)
			let reason = try decodeWindowReason(payload.reason)
			if version == 3 {
				guard case .reset = reason, payload.boundaryClock != nil else {
					throw RecordDecodeFailure(reason: "reset boundary")
				}
			}
			return .windowStart(
				WindowStartBody(
					chatId: try decodeChatID(payload.chatId),
					firstIncludedUlid: try decodeULID(payload.firstIncludedUlid),
					reason: reason,
					droppedMessageUlids: try payload.droppedMessageUlids?.map(decodeULID),
					boundaryClock: version == 3 ? payload.boundaryClock?.clock : nil
				)
			)
		case .compactionSummary:
			let payload = try payload(
				CompactionSummaryPayload.self, version: version, kind: name, data: data)
			return .compactionSummary(
				CompactionSummaryBody(
					chatId: try decodeChatID(payload.chatId), markdown: payload.markdown)
			)
		case .reviewApplied:
			let payload = try payload(
				ReviewAppliedPayload.self, version: version, kind: name, data: data)
			return .reviewApplied(try payload.body())
		case .memorySection:
			let payload = try payload(
				MemorySectionPayload.self, version: version, kind: name, data: data)
			return .memorySection(
				MemorySectionBody(
					name: SectionName(rawValue: payload.name), content: payload.content))
		case .dailyNote:
			let payload = try payload(
				DailyNotePayload.self, version: version, kind: name, data: data)
			return .dailyNote(DailyNoteBody(note: payload.note))
		case .ledgerEvent:
			let payload = try payload(
				LedgerEventPayload.self, version: version, kind: name, data: data)
			guard let eventKind = LedgerKind(rawValue: payload.kind),
				let source = LedgerSource(rawValue: payload.source)
			else {
				throw RecordDecodeFailure(reason: "ledger")
			}
			let date: CivilDate
			if let raw = payload.date {
				date = try decodeCivilDate(raw)
			} else if version == 1 {
				date = civilDate
			} else {
				throw RecordDecodeFailure(reason: "ledger date")
			}
			return .ledgerEvent(
				LedgerEventBody(date: date, kind: eventKind, text: payload.text, source: source))
		case .journal:
			let payload = try payload(JournalPayload.self, version: version, kind: name, data: data)
			guard let op = JournalOp(rawValue: payload.op) else {
				throw RecordDecodeFailure(reason: "journal")
			}
			return .journal(JournalBody(op: op, preview: payload.preview))
		case .provenance:
			let payload = try payload(
				ProvenancePayload.self, version: version, kind: name, data: data)
			return .provenance(
				ProvenanceBody(
					key: payload.key,
					garmin: payload.garmin,
					nonGarmin: payload.nonGarmin,
					unknown: payload.unknown,
					contentSha256: payload.contentSha256
				)
			)
		case .coachReplyLanguage:
			let payload = try payload(
				CoachReplyLanguagePayload.self, version: version, kind: name, data: data)
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
		case .planningDevice:
			let payload = try payload(
				PlanningDevicePayload.self, version: version, kind: name, data: data)
			return .planningDevice(
				PlanningDeviceBody(
					planningDeviceId: DeviceID(rawValue: payload.planningDeviceId),
					planUlid: try decodeULID(payload.planUlid),
					activatedAt: Date(timeIntervalSince1970: payload.activatedAt)
				)
			)
		case .sessionSettings:
			return .sessionSettings(
				try payload(SessionSettingsPayload.self, version: version, kind: name, data: data)
					.body())
		case .languagePreference:
			return .languagePreference(
				try payload(
					LanguagePreferencePayload.self, version: version, kind: name, data: data
				)
				.body())
		}
	}

}
