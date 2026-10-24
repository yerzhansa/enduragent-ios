import Foundation

package struct SavedPlanBody: Sendable, Equatable {
	let id: SavedPlanID
	let confirmation: PlanConfirmationID
	let decided: HybridLogicalClock
	let document: PlanDocument

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
