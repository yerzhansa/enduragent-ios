import Foundation

package enum ReviewWriteStatus: String, Sendable, Codable {
	case unverified
	case confirmed
	case rejected
}

package struct ReviewWriteBody: Sendable, Equatable {
	package let chatId: ChatID
	package let review: ChangeSetID
	package let status: ReviewWriteStatus
}

struct ReviewWritePayload: Codable {
	let chatId: String
	let review: String
	let status: ReviewWriteStatus

	init(_ body: ReviewWriteBody) {
		chatId = body.chatId.rawValue
		review = body.review.ulid.rawValue
		status = body.status
	}

	func body() throws -> ReviewWriteBody {
		ReviewWriteBody(
			chatId: try decodeChatID(chatId), review: ChangeSetID(ulid: try decodeULID(review)),
			status: status)
	}
}
