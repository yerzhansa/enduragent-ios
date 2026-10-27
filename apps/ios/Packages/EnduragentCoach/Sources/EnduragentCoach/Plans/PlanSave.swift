import Foundation

package struct SavedPlanBody: Sendable, Equatable {
	let id: SavedPlanID
	let confirmation: PlanConfirmationID
	let decided: HybridLogicalClock
	let document: PlanDocument

	fileprivate init(claimed: ClaimedSave) {
		id = claimed.claim.savedPlan
		confirmation = claimed.confirmation.id
		decided = claimed.decided
		document = claimed.confirmation.prepared.document
	}

	fileprivate init(
		id: SavedPlanID, confirmation: PlanConfirmationID, decided: HybridLogicalClock,
		document: PlanDocument
	) {
		self.id = id
		self.confirmation = confirmation
		self.decided = decided
		self.document = document
	}

	static func decode(_ payload: SavedPlanPayload) throws -> SavedPlanBody {
		SavedPlanBody(
			id: SavedPlanID(ulid: try decodeULID(payload.id)),
			confirmation: PlanConfirmationID(ulid: try decodeULID(payload.confirmation)),
			decided: payload.decided.clock,
			document: try PlanDocument.restore(
				text: payload.text, digest: PlanDigest(rawValue: payload.digest)))
	}
}

struct ClaimedSave: Sendable, Equatable {
	let confirmation: FoldedConfirmation
	let claim: SaveClaim
	let decided: HybridLogicalClock

	fileprivate init(
		confirmation: FoldedConfirmation, claim: SaveClaim, decided: HybridLogicalClock
	) {
		self.confirmation = confirmation
		self.claim = claim
		self.decided = decided
	}

	func stamp(zone: IANATimeZone) -> OperationStamp {
		confirmation.tapStamp(attempt: claim.attempt, zone: zone)
	}

	var savedPlan: SavedPlanBody { SavedPlanBody(claimed: self) }
}

extension FoldedConfirmation {
	func tapStamp(attempt: AttemptID, zone: IANATimeZone) -> OperationStamp {
		OperationStamp(
			operation: .planSave(id), attempt: attempt,
			binding: ActionBinding(account: prepared.account, zone: zone))
	}
}

enum PlanAdmission {
	static func admit(
		_ token: PlanSaveToken, as tap: PlanTap, delivery: PlanDelivery?, chain: PlanChain,
		at now: Date
	) -> Result<LiveConfirmation, PlanNotSaved> {
		guard
			let confirmation = chain.confirmations.first(where: { $0.id == token.ref.confirmation })
		else { return .failure(.notPresented) }
		switch chain.phase(of: confirmation, at: now) {
		case .saving, .saved, .canceled:
			return .failure(.alreadyDecided)
		case .expired:
			return .failure(.expired)
		case .replaced:
			return .failure(.replaced)
		case .live(let live):
			guard delivery?.admits(token) == true,
				token.ref.digest == confirmation.prepared.document.digest
			else { return .failure(.notPresented) }
			if case .save(let current) = tap,
				!confirmation.prepared.account.authority(under: current).permitsWrites
			{
				return .failure(.athleteChanged)
			}
			return .success(live)
		}
	}

	static func claim(_ live: LiveConfirmation, savedPlan: SavedPlanID, attempt: AttemptID)
		-> SaveClaim
	{
		SaveClaim(
			savedPlan: savedPlan, attempt: attempt,
			digest: live.confirmation.prepared.document.digest)
	}

	static func claimed(_ live: LiveConfirmation, appended record: PlanStepRecord) -> ClaimedSave? {
		guard record.body.confirmation == live.confirmation.id,
			case .claimed(let claim) = record.body.step
		else { return nil }
		return ClaimedSave(confirmation: live.confirmation, claim: claim, decided: record.hlc)
	}

	static func resumed(_ chain: PlanChain) -> [ClaimedSave] {
		chain.unfinishedClaims.map { confirmation, record, claim in
			ClaimedSave(confirmation: confirmation, claim: claim, decided: record.hlc)
		}
	}
}

enum PlanTap: Sendable, Equatable {
	case save(current: TrainingAccount)
	case cancel
}

enum SaveStep: Sendable, Equatable {
	case writeSavedPlan
	case appendSaved
	case done

	static func next(after latest: PlanConfirmationStep, stored: SavedPlanBody?) -> SaveStep {
		switch (latest, stored) {
		case (.claimed, nil): .writeSavedPlan
		case (.claimed, .some): .appendSaved
		case (.prepared, _), (.saved, _), (.canceled, _): .done
		}
	}
}

struct SavedPlanPayload: Codable {
	var id: String
	var confirmation: String
	var decided: HybridLogicalClockPayload
	var text: String
	var digest: String

	init(_ body: SavedPlanBody) {
		id = body.id.ulid.rawValue
		confirmation = body.confirmation.ulid.rawValue
		decided = HybridLogicalClockPayload(body.decided)
		text = body.document.text
		digest = body.document.digest.rawValue
	}
}
