import Foundation
import Testing

@testable import EnduragentCoach

@Suite struct ReviewWriteCodecTests {
	@Test(arguments: [
		("not-sent", CalendarWriteEvidence.notSent),
		("dispatched", .unknown(.dispatched)), ("absent", .unknown(.absent)),
		("found", .unknown(.found)), ("read-failed", .unknown(.readFailed)),
		("applied", .applied(eventID: 7)),
	])
	func evidenceMatchesGoldenBytes(name: String, evidence: CalendarWriteEvidence) throws {
		try golden(
			name: "calendar-write-\(name)", target: .create(date: "1998-06-14"), evidence: evidence)
	}

	@Test(arguments: [
		("update", CalendarWriteTarget.update(eventID: 7, date: "1998-06-14")),
		("delete", .delete(eventID: 7, date: "1998-06-14")),
	])
	func targetMatchesGoldenBytes(name: String, target: CalendarWriteTarget) throws {
		try golden(name: "calendar-write-\(name)", target: target, evidence: .notSent)
	}

	@Test(arguments: ["unverified", "rejected", "confirmed"])
	func legacyEvidenceDecodesConservatively(status: String) throws {
		let bytes = Data(try fixture("calendar-write-legacy-\(status)", ext: "json").utf8)
		let decoded = try RecordCodec.decode(
			kind: "reviewWrite", version: 2, data: bytes, civilDate: "1998-06-14",
			ulid: fixedUlid(2).rawValue
		).get()
		guard case .synced(.reviewWrite(let body)) = decoded else {
			Issue.record("expected a calendar intent")
			return
		}
		#expect(body.writeID == nil)
		#expect(
			body.evidence
				== (status == "confirmed" ? .applied(eventID: nil) : .unknown(.dispatched)))
	}

	@Test func legacyConfirmationDoesNotInventAnEventID() throws {
		let body = RecordBody.synced(
			.reviewWrite(
				ReviewWriteBody(
					chatId: .main,
					review: ChangeSetID(ulid: fixedUlid(1)), writeID: nil, target: nil,
					evidence: .applied(eventID: nil))))
		let bytes = Data(try fixture("calendar-write-legacy-applied", ext: "json").utf8)
		#expect(try RecordCodec.encode(body).data == bytes)
		#expect(
			try RecordCodec.decode(
				kind: "reviewWrite", version: 2, data: bytes, civilDate: "1998-06-14",
				ulid: fixedUlid(2).rawValue
			).get() == body)
	}

	@Test(arguments: ["unknown", "", "applied"])
	func unknownWriteStatusIsRejected(status: String) throws {
		let json = ["chatId": "main", "review": fixedUlid(1).rawValue, "status": status]
		let decoded = RecordCodec.decode(
			kind: "reviewWrite", version: 2, data: try JSONEncoder().encode(json),
			civilDate: "1998-06-14", ulid: fixedUlid(2).rawValue)
		#expect(decoded == .failure(.malformed(kind: "reviewWrite", ulid: fixedUlid(2).rawValue)))
	}

	private func golden(name: String, target: CalendarWriteTarget, evidence: CalendarWriteEvidence)
		throws
	{
		let id = try #require(UUID(uuidString: "10000000-0000-0000-0000-000000000001"))
		let body = RecordBody.synced(
			.reviewWrite(
				ReviewWriteBody(
					chatId: .main, review: ChangeSetID(ulid: fixedUlid(1)),
					writeID: CalendarWriteID(rawValue: id), target: target, evidence: evidence)))
		let bytes = Data(try fixture(name, ext: "json").utf8)
		#expect(try RecordCodec.encode(body).data == bytes)
		#expect(
			try RecordCodec.decode(
				kind: "reviewWrite", version: 2, data: bytes, civilDate: "1998-06-14",
				ulid: fixedUlid(2).rawValue
			).get() == body)
	}
}
