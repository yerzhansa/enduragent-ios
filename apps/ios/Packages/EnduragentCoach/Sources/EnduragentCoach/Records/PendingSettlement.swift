import Foundation

package struct PendingSettlementBody: Sendable, Equatable {
	let identity: ULID
	let settled: TurnSettledBody
}

struct PendingSettlementPayload: Codable {
	let identity: String
	let settled: TurnSettledPayload

	init(_ body: PendingSettlementBody) {
		identity = body.identity.rawValue
		settled = TurnSettledPayload(
			chatId: body.settled.chatId.rawValue, turn: body.settled.turn.ulid.rawValue,
			attempt: body.settled.attempt.ulid.rawValue,
			settlement: SettlementPayload(body.settled.settlement))
	}

	func body() throws -> PendingSettlementBody {
		PendingSettlementBody(
			identity: try decodeULID(identity),
			settled: TurnSettledBody(
				chatId: try decodeChatID(settled.chatId),
				turn: TurnID(ulid: try decodeULID(settled.turn)),
				attempt: AttemptID(ulid: try decodeULID(settled.attempt)),
				settlement: try settled.settlement.settlement()))
	}
}

extension AthleteRecord {
	var pendingSettlement: AthleteRecord? {
		guard case .deviceLocal(.pendingSettlement(let pending)) = body else { return nil }
		return AthleteRecord(
			ulid: pending.identity, deviceId: deviceId, hlc: hlc, timeZone: timeZone,
			civilDate: civilDate, cause: cause, account: account,
			body: .synced(.turnSettled(pending.settled)))
	}
}
