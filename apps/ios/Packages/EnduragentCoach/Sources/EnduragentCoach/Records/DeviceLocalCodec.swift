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
		case .openRouterKeyRejected:
			return .openRouterKeyRejected(
				try payload(
					RejectedOpenRouterKeyPayload.self, version: version, kind: name, data: data
				).reference)
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
		case .flushPending:
			let payload = try payload(
				FlushPendingPayload.self, version: version, kind: name, data: data)
			return .flushPending(
				FlushPendingBody(
					chatId: try decodeChatID(payload.chatId),
					messageUlids: try payload.messageUlids.map(decodeULID),
					sourceBound: version >= 5,
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
		case .workoutReview:
			return .workoutReview(WorkoutReviewBody(review: try WorkoutReviewPayload.decode(data)))
		case .reviewPreparing:
			let payload = try payload(
				TurnAttemptPayload.self, version: version, kind: name, data: data)
			return .reviewPreparing(
				ReviewPreparingBody(
					chatId: try decodeChatID(payload.chatId),
					turn: TurnID(ulid: try decodeULID(payload.turn)),
					attempt: AttemptID(ulid: try decodeULID(payload.attempt))
				)
			)
		case .planConfirmation:
			return .planConfirmation(
				try PlanConfirmationBody.decode(
					try payload(
						PlanConfirmationPayload.self, version: version, kind: name, data: data)))
		}
	}
}
