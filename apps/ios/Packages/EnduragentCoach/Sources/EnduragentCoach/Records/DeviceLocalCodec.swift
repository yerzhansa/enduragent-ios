import Foundation

extension RecordCodec {
	private static func decodeLease(_ raw: String?) throws -> LeaseKind {
		guard let raw else { return .gracePeriodOnly }
		guard let lease = LeaseKind(rawValue: raw) else {
			throw RecordDecodeFailure(reason: "lease")
		}
		return lease
	}

	static func deviceLocalBody(_ kind: DeviceLocalKind, version: Int, data: Data) throws
		-> DeviceLocalRecordBody
	{
		let name = kind.rawValue
		switch kind {
		case .providerConsent:
			return .providerConsent(
				try payload(ProviderConsentPayload.self, version: version, kind: name, data: data)
					.body())
		case .turnClaim:
			let payload = try payload(
				TurnClaimPayload.self, version: version, kind: name, data: data)
			return .turnClaim(
				TurnClaimBody(
					chatId: try decodeChatID(payload.chatId),
					turn: TurnID(ulid: try decodeULID(payload.turn)),
					attempt: AttemptID(ulid: try decodeULID(payload.attempt)),
					process: try payload.process.map { ProcessID(ulid: try decodeULID($0)) },
					lease: try decodeLease(payload.lease)
				)
			)
		case .replyObserved:
			let payload = try payload(
				TurnAttemptPayload.self, version: version, kind: name, data: data)
			return .replyObserved(
				ReplyObservedBody(
					chatId: try decodeChatID(payload.chatId),
					turn: TurnID(ulid: try decodeULID(payload.turn)),
					attempt: AttemptID(ulid: try decodeULID(payload.attempt))
				)
			)
		case .pendingSettlement:
			return .pendingSettlement(
				try payload(TurnSettledPayload.self, version: version, kind: name, data: data)
					.body())
		case .pendingProposal:
			let payload = try payload(
				ProposalPayload.self, version: version, kind: name, data: data)
			guard let tool = GatedToolName(rawValue: payload.tool) else {
				throw RecordDecodeFailure(reason: "tool")
			}
			return .pendingProposal(
				ProposalBody(
					writeID: payload.writeID.map(CalendarWriteID.init(rawValue:)),
					chatId: try decodeChatID(payload.chatId),
					nonce: Nonce(rawValue: payload.nonce),
					tool: tool,
					toolInput: try payload.toolInput.gatedToolInput(),
					summary: payload.summary,
					description: payload.description,
					expiresAt: Date(timeIntervalSince1970: payload.expiresAt)
				)
			)
		case .proposalCleared:
			let payload = try payload(
				ProposalClearedPayload.self, version: version, kind: name, data: data)
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
		case .flushPending:
			let payload = try payload(
				FlushPendingPayload.self, version: version, kind: name, data: data)
			return .flushPending(
				FlushPendingBody(
					chatId: try decodeChatID(payload.chatId),
					messageUlids: try payload.messageUlids.map(decodeULID),
					process: try payload.process.map { ProcessID(ulid: try decodeULID($0)) }
				)
			)
		case .flushSettled:
			let payload = try payload(
				FlushSettledPayload.self, version: version, kind: name, data: data)
			return .flushSettled(
				FlushSettledBody(
					chatId: try decodeChatID(payload.chatId),
					job: FlushJobID(ulid: try decodeULID(payload.job)),
					settlement: try payload.settlement()
				)
			)
		case .planningCommand:
			let payload = try payload(
				PlanningCommandPayload.self, version: version, kind: name, data: data)
			guard let commandName = PlanningCommandName(rawValue: payload.commandName),
				let status = PlanningCommandStatus(rawValue: payload.status)
			else {
				throw RecordDecodeFailure(reason: "planningCommand")
			}
			return .planningCommand(
				PlanningCommandBody(
					commandName: commandName,
					commandId: payload.commandId,
					requestDigest: payload.requestDigest,
					status: status,
					result: payload.result?.value
				)
			)
		case .planRevision:
			let payload = try payload(
				PlanRevisionPayload.self, version: version, kind: name, data: data)
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
		case .mirrorJob:
			let payload = try payload(
				MirrorJobPayload.self, version: version, kind: name, data: data)
			guard let jobKind = MirrorJobKind(rawValue: payload.kind),
				let windowStart = DateKey(rawValue: payload.windowStart),
				let windowEnd = DateKey(rawValue: payload.windowEnd)
			else {
				throw RecordDecodeFailure(reason: "mirror")
			}
			return .mirrorJob(
				MirrorJobBody(
					planUlid: try decodeULID(payload.planUlid),
					kind: jobKind,
					windowStart: windowStart,
					windowEnd: windowEnd,
					failureCount: payload.failureCount
				)
			)
		case .workoutMatch:
			let payload = try payload(
				WorkoutMatchPayload.self, version: version, kind: name, data: data)
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
		case .workoutDrift:
			let payload = try payload(
				WorkoutDriftPayload.self, version: version, kind: name, data: data)
			return .workoutDrift(
				WorkoutDriftBody(
					planWorkoutId: try decodeULID(payload.planWorkoutId),
					askedAt: Date(timeIntervalSince1970: payload.askedAt)
				)
			)
		}
	}
}
