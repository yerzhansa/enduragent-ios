import Foundation
import Testing

@testable import EnduragentCoach

@Suite struct ReviewWriteCodecTests {
	@Test(arguments: [ReviewWriteStatus.unverified, .confirmed, .rejected])
	func reviewWriteRoundTrips(status: ReviewWriteStatus) throws {
		let body = RecordBody.synced(
			.reviewWrite(
				ReviewWriteBody(
					chatId: .main, review: ChangeSetID(ulid: fixedUlid(1)), status: status)))
		let encoded = try RecordCodec.encode(body)
		let decoded = RecordCodec.decode(
			kind: "reviewWrite", version: encoded.version, data: encoded.data,
			civilDate: "1998-06-14", ulid: fixedUlid(2).rawValue)
		#expect(try decoded.get() == body)
	}

	@Test(arguments: ["unknown", "", "applied"])
	func unknownWriteStatusIsRejected(status: String) throws {
		let json: [String: String] = [
			"chatId": "main", "review": fixedUlid(1).rawValue, "status": status,
		]
		let decoded = RecordCodec.decode(
			kind: "reviewWrite", version: 2, data: try JSONEncoder().encode(json),
			civilDate: "1998-06-14", ulid: fixedUlid(2).rawValue)
		#expect(decoded == .failure(.malformed(kind: "reviewWrite", ulid: fixedUlid(2).rawValue)))
	}
}
