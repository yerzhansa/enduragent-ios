import EnduragentCoachFixtures
import Foundation

@testable import EnduragentCoach

enum SavedPlanRows {
	static let version = 7

	static func body(
		_ plan: JSONValue, id: Int = 1, confirmation: Int = 2,
		decided: HybridLogicalClock = HybridLogicalClock(
			wallMs: 1, logical: 0, deviceId: DeviceID(rawValue: "plan-phone"))
	) throws -> RecordBody {
		let document = try PlanDocument.parse(arguments: .object(["plan": plan]))
		return try decode(
			payload(
				text: document.text, digest: document.digest.rawValue, id: id,
				confirmation: confirmation, decided: decided)
		).get()
	}

	static func payload(
		text: String, digest: String, id: Int, confirmation: Int, decided: HybridLogicalClock
	) -> JSONValue {
		.object([
			"id": .string(fixedUlid(id).rawValue),
			"confirmation": .string(fixedUlid(confirmation).rawValue),
			"decided": .object([
				"wallMs": .number(Double(decided.wallMs)),
				"logical": .number(Double(decided.logical)),
				"deviceId": .string(decided.deviceId.rawValue),
			]),
			"text": .string(text),
			"digest": .string(digest),
		])
	}

	static func decode(_ payload: JSONValue, version: Int = version)
		-> Result<RecordBody, SkippedRow>
	{
		RecordCodec.decode(
			kind: SavedPlans.kind.rawValue, version: version,
			data: Data(payload.canonicalDigestInput().utf8), civilDate: "1998-06-13",
			ulid: "saved-plan-row")
	}
}
