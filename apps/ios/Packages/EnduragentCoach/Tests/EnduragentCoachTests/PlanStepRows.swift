import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

struct PlanStepRows {
	static let version = 7
	static let phone = DeviceID(rawValue: "plan-phone")

	let chat: ChatID
	let id: PlanConfirmationID
	let origin: DraftKey

	init(confirmation: Int, turn: Int, attempt: Int? = nil, chat: ChatID = .main) {
		self.chat = chat
		id = PlanConfirmationID(ulid: fixedUlid(confirmation))
		origin = DraftKey(
			turn: TurnID(ulid: fixedUlid(turn)),
			attempt: AttemptID(ulid: fixedUlid(attempt ?? turn + 1)))
	}

	func prepared(
		_ plan: JSONValue, account: TrainingAccount = .unconnected, expiresAt: Date
	) throws -> RecordBody {
		let document = try PlanDocument.parse(arguments: .object(["plan": plan]))
		return try body(
			.object([
				"prepared": .object([
					"text": .string(document.text), "digest": .string(document.digest.rawValue),
					"account": .string(account.storedValue),
					"expiresAt": .number(expiresAt.timeIntervalSinceReferenceDate),
				])
			]))
	}

	func claimed(_ row: PlanClaimRow) throws -> RecordBody {
		try body(.object(["claimed": row.payload]))
	}

	func saved(_ id: SavedPlanID) throws -> RecordBody {
		try body(.object(["saved": .object(["savedPlan": .string(id.ulid.rawValue)])]))
	}

	func canceled() throws -> RecordBody {
		try body(.object(["canceled": .object([:])]))
	}

	func step(_ body: RecordBody, wall: Int64) throws -> PlanStepRecord {
		try #require(
			PlanStepRecord(
				storedRecord(device: Self.phone, wall: wall, ulid: fixedUlid(Int(wall)), body: body)
			))
	}

	private func body(_ step: JSONValue) throws -> RecordBody {
		let payload: JSONValue = .object([
			"chat": .string(chat.rawValue), "confirmation": .string(id.ulid.rawValue),
			"turn": .string(origin.turn.ulid.rawValue),
			"attempt": .string(origin.attempt.ulid.rawValue), "step": step,
		])
		return try RecordCodec.decode(
			kind: PlanChain.kind.rawValue, version: Self.version,
			data: Data(payload.canonicalDigestInput().utf8), civilDate: "1998-06-13",
			ulid: "plan-step-row"
		).get()
	}
}

struct PlanClaimRow {
	let claim: SaveClaim
	let payload: JSONValue

	init(savedPlan: Int, attempt: Int, for plan: JSONValue) throws {
		let digest = try PlanDocument.parse(arguments: .object(["plan": plan])).digest
		claim = SaveClaim(
			savedPlan: SavedPlanID(ulid: fixedUlid(savedPlan)),
			attempt: AttemptID(ulid: fixedUlid(attempt)), digest: digest)
		payload = .object([
			"savedPlan": .string(fixedUlid(savedPlan).rawValue),
			"attempt": .string(fixedUlid(attempt).rawValue), "digest": .string(digest.rawValue),
		])
	}
}
