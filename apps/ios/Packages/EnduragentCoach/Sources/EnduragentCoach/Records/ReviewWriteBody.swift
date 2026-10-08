import Foundation

package struct CalendarWriteID: Hashable, Sendable, Codable {
	package let rawValue: UUID

	package init(rawValue: UUID = UUID()) { self.rawValue = rawValue }

	package var uid: String { rawValue.uuidString }
	package var externalID: String { "cycling-coach:\(uid)" }
}

package enum CalendarWriteKey: Hashable, Sendable {
	case durable(CalendarWriteID)
	case legacy(ChangeSetID)
}

package enum CalendarObservation: String, Sendable, Codable {
	case dispatched
	case absent
	case found
	case readFailed
}

package enum CalendarWriteEvidence: Sendable, Equatable, Codable {
	case notSent
	case unknown(CalendarObservation)
	case applied(eventID: Int?)

	package var applied: Bool {
		if case .applied = self { return true }
		return false
	}

	package var dispatched: Bool { self != .notSent }

	package func merging(_ next: Self) -> Self {
		if applied { return self }
		if dispatched && next == .notSent { return self }
		return next
	}
}

package enum CalendarWriteTarget: Sendable, Equatable, Codable {
	case create(date: String)
	case update(eventID: Int, date: String)
	case delete(eventID: Int, date: String)
}

package struct ReviewWriteBody: Sendable, Equatable {
	package let chatId: ChatID
	package let review: ChangeSetID
	package let writeID: CalendarWriteID?
	package let target: CalendarWriteTarget?
	package var evidence: CalendarWriteEvidence

	package var key: CalendarWriteKey {
		writeID.map(CalendarWriteKey.durable) ?? .legacy(review)
	}
}

struct ReviewWritePayload: Codable {
	let chatId: String
	let review: String
	let writeID: UUID?
	let target: CalendarWriteTarget?
	let evidence: CalendarWriteEvidence

	init(_ body: ReviewWriteBody) {
		chatId = body.chatId.rawValue
		review = body.review.ulid.rawValue
		writeID = body.writeID?.rawValue
		target = body.target
		evidence = body.evidence
	}

	private enum CodingKeys: String, CodingKey {
		case chatId, review, writeID, target, evidence, status
	}

	init(from decoder: Decoder) throws {
		let values = try decoder.container(keyedBy: CodingKeys.self)
		chatId = try values.decode(String.self, forKey: .chatId)
		review = try values.decode(String.self, forKey: .review)
		writeID = try values.decodeIfPresent(UUID.self, forKey: .writeID)
		target = try values.decodeIfPresent(CalendarWriteTarget.self, forKey: .target)
		if values.contains(.evidence) {
			evidence = try values.decode(CalendarWriteEvidence.self, forKey: .evidence)
		} else {
			switch try values.decode(String.self, forKey: .status) {
			case "confirmed": evidence = .applied(eventID: nil)
			case "unverified", "rejected": evidence = .unknown(.dispatched)
			default: throw RecordDecodeFailure(reason: "reviewWrite status")
			}
		}
	}

	func encode(to encoder: Encoder) throws {
		var values = encoder.container(keyedBy: CodingKeys.self)
		try values.encode(chatId, forKey: .chatId)
		try values.encode(review, forKey: .review)
		try values.encodeIfPresent(writeID, forKey: .writeID)
		try values.encodeIfPresent(target, forKey: .target)
		try values.encode(evidence, forKey: .evidence)
	}

	func body() throws -> ReviewWriteBody {
		guard writeID == nil || (target != nil && evidence != .applied(eventID: nil)) else {
			throw RecordDecodeFailure(reason: "reviewWrite target")
		}
		return ReviewWriteBody(
			chatId: try decodeChatID(chatId), review: ChangeSetID(ulid: try decodeULID(review)),
			writeID: writeID.map(CalendarWriteID.init(rawValue:)), target: target,
			evidence: evidence)
	}
}
