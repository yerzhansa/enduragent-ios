import Foundation
import Testing

@testable import EnduragentCoach

@Suite struct TurnClaimCodecTests {
	@Test func aClaimWrittenBeforeLeasesExistedReadsAsGracePeriodOnly() throws {
		let legacy = Data(
			#"{"attempt":"01J0000000000000000000000B","chatId":"main","turn":"01J0000000000000000000000A"}"#
				.utf8)
		let decoded = RecordCodec.decode(
			kind: "turnClaim", version: 2, data: legacy, civilDate: "1998-06-13",
			ulid: "01J0000000000000000000000C")
		guard case .success(.deviceLocal(.turnClaim(let claim))) = decoded else {
			Issue.record("expected a claim, got \(decoded)")
			return
		}
		#expect(claim.lease == .gracePeriodOnly)
		let unknown = Data(
			#"{"attempt":"01J0000000000000000000000B","chatId":"main","lease":"forever","turn":"01J0000000000000000000000A"}"#
				.utf8)
		let refused = RecordCodec.decode(
			kind: "turnClaim", version: 2, data: unknown, civilDate: "1998-06-13",
			ulid: "01J0000000000000000000000C")
		#expect(
			refused == .failure(.malformed(kind: "turnClaim", ulid: "01J0000000000000000000000C")))
	}
}
