import Foundation

package struct ReviewOutcomeBody: Sendable, Equatable {
	package enum Ending: String, Sendable, Equatable {
		case completed
		case canceled
		case closedAtUpgrade
	}

	package let chatId: ChatID
	package let review: WorkoutReviewID
	package let revision: ReviewRevision
	package let after: TurnID?
	package let ending: Ending
	package let lines: [OutcomeLine]
}

package struct OutcomeLine: Sendable, Equatable {
	package enum Result: String, Sendable, Equatable {
		case saved
		case seenOnCalendar
		case noLongerOnCalendar
		case givenUp
		case mayHaveBeenSaved
	}

	package let position: Int
	package let action: ReviewCard.Action
	package let name: String
	package let date: CivilDate
	package let result: Result
}

struct ReviewOutcomePayload: Codable {
	let chatId: String
	let review: String
	let revision: Int
	let after: String?
	let ending: String
	let lines: [OutcomeLinePayload]

	init(_ body: ReviewOutcomeBody) {
		chatId = body.chatId.rawValue
		review = body.review.ulid.rawValue
		revision = body.revision.rawValue
		after = body.after?.ulid.rawValue
		ending = body.ending.rawValue
		lines = body.lines.map(OutcomeLinePayload.init)
	}

	func body() throws -> ReviewOutcomeBody {
		guard let ending = ReviewOutcomeBody.Ending(rawValue: ending), revision >= 1 else {
			throw RecordDecodeFailure(reason: "reviewOutcome")
		}
		return ReviewOutcomeBody(
			chatId: try decodeChatID(chatId),
			review: WorkoutReviewID(ulid: try decodeULID(review)),
			revision: ReviewRevision(rawValue: revision),
			after: try after.map { TurnID(ulid: try decodeULID($0)) },
			ending: ending,
			lines: try lines.map { try $0.line() })
	}
}

struct OutcomeLinePayload: Codable {
	enum Action: Codable {
		case add
		case edit(previousName: String?)
		case delete
	}

	let position: Int
	let action: Action
	let name: String
	let date: String
	let result: String

	init(_ line: OutcomeLine) {
		position = line.position
		action =
			switch line.action {
			case .add: .add
			case .edit(let previousName): .edit(previousName: previousName)
			case .delete: .delete
			}
		name = line.name
		date = line.date.rawValue
		result = line.result.rawValue
	}

	func line() throws -> OutcomeLine {
		guard let result = OutcomeLine.Result(rawValue: result) else {
			throw RecordDecodeFailure(reason: "reviewOutcome line")
		}
		let action: ReviewCard.Action =
			switch action {
			case .add: .add
			case .edit(let previousName): .edit(previousName: previousName)
			case .delete: .delete
			}
		return OutcomeLine(
			position: position, action: action, name: name, date: try decodeCivilDate(date),
			result: result)
	}
}
