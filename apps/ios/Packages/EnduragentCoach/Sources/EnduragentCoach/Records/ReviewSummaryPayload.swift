import Foundation

struct ReviewAppliedPayload: Codable {
	var chatId: String
	var summary: String?
	var change: ReviewSummaryPayload?

	init(_ body: ReviewAppliedBody) {
		chatId = body.chatId.rawValue
		if case .supplied(let text) = body.summary {
			summary = text
		} else {
			change = ReviewSummaryPayload(body.summary)
		}
	}

	func body() throws -> ReviewAppliedBody {
		let value: ReviewSummary
		switch (summary, change) {
		case (.some(let text), .none): value = .supplied(text)
		case (.none, .some(let structured)): value = try structured.value()
		case (.none, .none), (.some, .some):
			throw RecordDecodeFailure(reason: "review summary")
		}
		return ReviewAppliedBody(chatId: try decodeChatID(chatId), summary: value)
	}
}

enum ReviewSummaryPayload: Codable {
	case createWorkout(name: String, date: String)
	case createStrengthWorkout(name: String, date: String)
	case deleteWorkout
	case updateWorkout(date: String?, name: String?, descriptionChanged: Bool)
	case planSave(name: String)

	init?(_ summary: ReviewSummary) {
		switch summary {
		case .supplied: return nil
		case .createWorkout(let name, let date):
			self = .createWorkout(name: name, date: date.rawValue)
		case .createStrengthWorkout(let name, let date):
			self = .createStrengthWorkout(name: name, date: date.rawValue)
		case .deleteWorkout: self = .deleteWorkout
		case .updateWorkout(let date, let name, let descriptionChanged):
			self = .updateWorkout(
				date: date?.rawValue, name: name, descriptionChanged: descriptionChanged)
		case .planSave(let name): self = .planSave(name: name)
		}
	}

	func value() throws -> ReviewSummary {
		switch self {
		case .createWorkout(let name, let date):
			return .createWorkout(name: name, date: try decodeCivilDate(date))
		case .createStrengthWorkout(let name, let date):
			return .createStrengthWorkout(name: name, date: try decodeCivilDate(date))
		case .deleteWorkout: return .deleteWorkout
		case .updateWorkout(let date, let name, let descriptionChanged):
			return .updateWorkout(
				date: try date.map(decodeCivilDate), name: name,
				descriptionChanged: descriptionChanged)
		case .planSave(let name): return .planSave(name: name)
		}
	}
}
