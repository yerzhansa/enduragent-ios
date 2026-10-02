import Foundation
import Testing

@testable import EnduragentCoach

@Suite struct PendingSettlementCodecTests {
	static let fixtures: [(String, Settlement)] = [
		(
			"pending-settlement-replied",
			.replied(
				.model("Keep this exact reply.\nTwo rides, 3 h 10 min."),
				lineage: ReplyLineage(templateHash: "template", assembledHash: "assembled"))
		),
		(
			"pending-settlement-interrupted",
			.interrupted(partial: "Partial reply\nKeep it.", cause: .athleteStopped, saved: .none)
		),
	]

	@Test(arguments: fixtures)
	func pendingSettlementEncodesExactSortedBytes(fixture: String, settlement: Settlement) throws {
		let encoded = try RecordCodec.encode(body(settlement))
		#expect(encoded.version == 2)
		#expect(encoded.data == (try fixtureData(fixture)))
	}

	@Test(arguments: fixtures)
	func pendingSettlementDecodesExactBytes(fixture: String, settlement: Settlement) throws {
		let decoded = RecordCodec.decode(
			kind: "pendingSettlement", version: 2, data: try fixtureData(fixture),
			civilDate: "1998-06-13", ulid: "01J0000000000000000000000C")
		#expect(try decoded.get() == body(settlement))
	}

	private func body(_ settlement: Settlement) throws -> RecordBody {
		.deviceLocal(
			.pendingSettlement(
				TurnSettledBody(
					chatId: .main,
					turn: TurnID(ulid: try #require(ULID(rawValue: "01J0000000000000000000000A"))),
					attempt: AttemptID(
						ulid: try #require(ULID(rawValue: "01J0000000000000000000000B"))),
					settlement: settlement)))
	}
}
