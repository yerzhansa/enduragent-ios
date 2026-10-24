import Foundation

package struct PlanConfirmationBody: Sendable, Equatable {
	let chat: ChatID
	let confirmation: PlanConfirmationID
	let origin: DraftKey
	let step: PlanConfirmationStep

	var turn: TurnID { origin.turn }
}

enum PlanConfirmationStep: Sendable, Equatable {
	case prepared(PreparedPlanSave)
	case claimed(SaveClaim)
	case saved(SavedPlanID)
	case canceled
}

struct PreparedPlanSave: Sendable, Equatable {
	let document: PlanDocument
	let account: TrainingAccount
	let expiresAt: Date
}

struct SaveClaim: Sendable, Equatable {
	let savedPlan: SavedPlanID
	let attempt: AttemptID
	let digest: PlanDigest
}

struct PlanStepRecord: Sendable, Equatable {
	let ulid: ULID
	let hlc: HybridLogicalClock
	let body: PlanConfirmationBody

	init?(_ record: AthleteRecord) {
		guard case .deviceLocal(.planConfirmation(let body)) = record.body else { return nil }
		ulid = record.ulid
		hlc = record.hlc
		self.body = body
	}
}

struct FoldedConfirmation: Sendable, Equatable {
	let id: PlanConfirmationID
	let origin: DraftKey
	let prepared: PreparedPlanSave
	let created: PlanStepRecord
	let decided: PlanStepRecord?
	let newest: PlanStepRecord

	var latest: PlanConfirmationStep { newest.body.step }

	var expiry: Date { created.hlc.wallTime.addingTimeInterval(Plans.lifetime / .seconds(1)) }

	fileprivate func advanced(to record: PlanStepRecord) -> FoldedConfirmation {
		FoldedConfirmation(
			id: id, origin: origin, prepared: prepared, created: created,
			decided: decided ?? record, newest: record)
	}
}

struct PlanChain: Sendable, Equatable {
	static let kind: DeviceLocalKind = .planConfirmation

	let head: RecordHead
	let confirmations: [FoldedConfirmation]

	init(head: RecordHead, records: [PlanStepRecord]) {
		var folded: [FoldedConfirmation] = []
		for record in records {
			let id = record.body.confirmation
			if let index = folded.firstIndex(where: { $0.id == id }) {
				folded[index] = folded[index].advanced(to: record)
			} else if case .prepared(let prepared) = record.body.step {
				folded.append(
					FoldedConfirmation(
						id: id, origin: record.body.origin, prepared: prepared, created: record,
						decided: nil, newest: record))
			}
		}
		self.head = head
		confirmations = folded
	}

	var newest: FoldedConfirmation? { confirmations.last }

	func committed(by key: DraftKey) -> FoldedConfirmation? {
		confirmations.last { $0.origin == key }
	}

	var unfinishedClaims: [(FoldedConfirmation, PlanStepRecord, SaveClaim)] {
		confirmations.compactMap { confirmation in
			guard case .claimed(let claim) = confirmation.latest else { return nil }
			return (confirmation, confirmation.newest, claim)
		}
	}

	func phase(of confirmation: FoldedConfirmation, at now: Date) -> ConfirmationPhase {
		switch confirmation.latest {
		case .claimed(let claim):
			return .saving(claim)
		case .saved(let id):
			return .saved(id)
		case .canceled:
			return .canceled
		case .prepared:
			if now >= confirmation.prepared.expiresAt { return .expired }
			guard newest?.id == confirmation.id else { return .replaced }
			return .live(LiveConfirmation(confirmation: confirmation, head: head))
		}
	}

	func end(of confirmation: FoldedConfirmation) -> ConfirmationEnd {
		if let decided = confirmation.decided { return .step(decided.hlc) }
		let expiry = ConfirmationEnd.expiry(confirmation.expiry)
		guard
			let replacing = confirmations.drop(while: { $0.id != confirmation.id }).dropFirst()
				.first,
			expiry.comesAfter(replacing.created.hlc)
		else { return expiry }
		return .step(replacing.created.hlc)
	}
}

enum ConfirmationEnd: Sendable, Equatable {
	case step(HybridLogicalClock)
	case expiry(Date)

	func comesAfter(_ clock: HybridLogicalClock) -> Bool {
		switch self {
		case .step(let step): clock < step
		case .expiry(let instant): clock.wallTime < instant
		}
	}
}

enum ConfirmationPhase: Sendable, Equatable {
	case live(LiveConfirmation)
	case saving(SaveClaim)
	case saved(SavedPlanID)
	case canceled
	case expired
	case replaced
}

struct LiveConfirmation: Sendable, Equatable {
	let confirmation: FoldedConfirmation
	let head: RecordHead

	fileprivate init(confirmation: FoldedConfirmation, head: RecordHead) {
		self.confirmation = confirmation
		self.head = head
	}
}

extension RecordQuery {
	static func planChain(of chat: ChatID) -> RecordQuery {
		RecordQuery(scope: .deviceLocal([PlanChain.kind]), chatId: chat)
	}
}

extension PlanConfirmationBody {
	static func decode(_ payload: PlanConfirmationPayload) throws -> PlanConfirmationBody {
		PlanConfirmationBody(
			chat: try decodeChatID(payload.chat),
			confirmation: PlanConfirmationID(ulid: try decodeULID(payload.confirmation)),
			origin: DraftKey(
				turn: TurnID(ulid: try decodeULID(payload.turn)),
				attempt: AttemptID(ulid: try decodeULID(payload.attempt))),
			step: try payload.step.step())
	}
}

struct PlanConfirmationPayload: Codable {
	var chat: String
	var confirmation: String
	var turn: String
	var attempt: String
	var step: PlanStepPayload

	init(_ body: PlanConfirmationBody) {
		chat = body.chat.rawValue
		confirmation = body.confirmation.ulid.rawValue
		turn = body.origin.turn.ulid.rawValue
		attempt = body.origin.attempt.ulid.rawValue
		step = PlanStepPayload(body.step)
	}
}

enum PlanStepPayload: Codable {
	case prepared(text: String, digest: String, account: String, expiresAt: Double)
	case claimed(savedPlan: String, attempt: String, digest: String)
	case saved(savedPlan: String)
	case canceled

	init(_ step: PlanConfirmationStep) {
		switch step {
		case .prepared(let prepared):
			self = .prepared(
				text: prepared.document.text, digest: prepared.document.digest.rawValue,
				account: prepared.account.storedValue,
				expiresAt: prepared.expiresAt.timeIntervalSinceReferenceDate)
		case .claimed(let claim):
			self = .claimed(
				savedPlan: claim.savedPlan.ulid.rawValue, attempt: claim.attempt.ulid.rawValue,
				digest: claim.digest.rawValue)
		case .saved(let id):
			self = .saved(savedPlan: id.ulid.rawValue)
		case .canceled:
			self = .canceled
		}
	}

	func step() throws -> PlanConfirmationStep {
		switch self {
		case .prepared(let text, let digest, let account, let expiresAt):
			return .prepared(
				PreparedPlanSave(
					document: try PlanDocument.restore(
						text: text, digest: PlanDigest(rawValue: digest)),
					account: try decodeAccount(account),
					expiresAt: Date(timeIntervalSinceReferenceDate: expiresAt)))
		case .claimed(let savedPlan, let attempt, let digest):
			return .claimed(
				SaveClaim(
					savedPlan: SavedPlanID(ulid: try decodeULID(savedPlan)),
					attempt: AttemptID(ulid: try decodeULID(attempt)),
					digest: PlanDigest(rawValue: digest)))
		case .saved(let savedPlan):
			return .saved(SavedPlanID(ulid: try decodeULID(savedPlan)))
		case .canceled:
			return .canceled
		}
	}
}
