import Foundation
import Testing

@testable import EnduragentCoach

@Suite struct ProposalIdentityCodecTests {
	@Test(arguments: [false, true])
	func proposalIdentityMatchesGoldenBytes(legacy: Bool) throws {
		let id = try #require(UUID(uuidString: "10000000-0000-0000-0000-000000000001"))
		let nonce = try #require(UUID(uuidString: "20000000-0000-0000-0000-000000000001"))
		let body = RecordBody.deviceLocal(
			.pendingProposal(
				ProposalBody(
					writeID: legacy ? nil : CalendarWriteID(rawValue: id), chatId: .main,
					nonce: Nonce(rawValue: nonce), tool: .intervalsCreateStrengthWorkout,
					toolInput: .createStrengthWorkout(
						date: "1998-06-14", name: "Strength", description: "Three sets"),
					summary: "Strength", description: "Three sets",
					expiresAt: Date(timeIntervalSince1970: 897_739_800))))
		let bytes = Data(
			try fixture(
				legacy ? "proposal-legacy-identity" : "proposal-durable-identity", ext: "json"
			).utf8)
		#expect(try RecordCodec.encode(body).data == bytes)
		#expect(
			try RecordCodec.decode(
				kind: "pendingProposal", version: 2, data: bytes, civilDate: "1998-06-14",
				ulid: fixedUlid(2).rawValue
			).get() == body)
	}
}
