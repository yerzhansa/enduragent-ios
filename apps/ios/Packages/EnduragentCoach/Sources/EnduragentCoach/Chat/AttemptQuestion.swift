import Foundation

package struct AttemptQuestionBody: Sendable, Equatable {
	package let chatId: ChatID
	package let turn: TurnID
	package let athleteText: String
}

struct AttemptQuestionPayload: Codable {
	let chatId: String
	let turn: String
	let athleteText: String

	init(_ body: AttemptQuestionBody) {
		chatId = body.chatId.rawValue
		turn = body.turn.ulid.rawValue
		athleteText = body.athleteText
	}

	func body() throws -> AttemptQuestionBody {
		AttemptQuestionBody(
			chatId: try decodeChatID(chatId), turn: TurnID(ulid: try decodeULID(turn)),
			athleteText: athleteText)
	}
}

struct AttemptQuestion: Sendable, Equatable {
	let attempt: AttemptID
	let row: ConversationRow
}

extension TurnFacts {
	func questionRow(for attempt: AttemptID?, using ownership: InformationOwnership)
		-> ConversationRow?
	{
		guard let original = userRow, let attempt,
			let question = questions.first(where: { $0.attempt == attempt })?.row
		else { return userRow }
		let originalOwner = ownership.rowOwner(account: original.account, origin: original.origin)
		let owner = ownership.rowOwner(account: question.account, origin: question.origin)
		return owner == originalOwner ? original : question
	}

	func messageRows(using ownership: InformationOwnership) -> [ConversationRow] {
		guard let original = userRow else { return [] }
		var replies: [InformationOwner: SettledAttempt] = [:]
		for settled in settlements.sorted(by: { $0.hlc < $1.hlc }) {
			let account = claims.first { $0.attempt == settled.attempt }?.account ?? settled.account
			replies[ownership.rowOwner(account: account, origin: settled.origin)] = settled
		}
		if let claim = openClaim {
			let device = questions.first { $0.attempt == claim.attempt }?.row.origin ?? origin
			replies[ownership.rowOwner(account: claim.account, origin: device)] = nil
		}
		let readable = replies.values.filter { replyRow(for: $0) != nil }.sorted(by: {
			$0.hlc < $1.hlc
		})
		guard !readable.isEmpty else { return legacy && latestSettlement == nil ? [original] : [] }
		var rows = [original]
		for settled in readable {
			if let question = questionRow(for: settled.attempt, using: ownership),
				question.ulid != original.ulid
			{
				rows.append(question)
			}
			if let reply = replyRow(for: settled) { rows.append(reply) }
		}
		return rows
	}
}
