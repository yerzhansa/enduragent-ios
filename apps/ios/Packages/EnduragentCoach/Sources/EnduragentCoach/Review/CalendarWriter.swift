import Foundation

package struct Receipt: Hashable, Sendable, Codable {
	package let event: EventID
	package let answeredAt: Date

	fileprivate init(event: EventID, answeredAt: Date) {
		self.event = event
		self.answeredAt = answeredAt
	}

	private enum CodingKeys: String, CodingKey {
		case event, answeredAt
	}

	package init(from decoder: any Decoder) throws {
		let values = try decoder.container(keyedBy: CodingKeys.self)
		self.init(
			event: EventID(rawValue: try values.decode(Int.self, forKey: .event)),
			answeredAt: Date(
				timeIntervalSince1970: try values.decode(Double.self, forKey: .answeredAt)))
	}

	package func encode(to encoder: any Encoder) throws {
		var values = encoder.container(keyedBy: CodingKeys.self)
		try values.encode(event.rawValue, forKey: .event)
		try values.encode(answeredAt.timeIntervalSince1970, forKey: .answeredAt)
	}
}

package enum LostAnswer: Equatable, Sendable {
	case transport
	case unreadableBody
	case canceled
	case serverStatus(Int)
	case answerNamesOtherEvent
}

package enum SendAnswer: Equatable, Sendable {
	case saved(Receipt)
	case gone
	case refused(RefusalStatus)
	case lost(LostAnswer)
}

package enum SettleRead: Equatable, Sendable {
	case seen(EventID)
	case gone
	case notSaved
	case readFailed
}
