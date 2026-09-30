import Foundation
import Testing

@testable import EnduragentCoach

@Suite struct WriteSummaryCodecTests {
	@Test func legacyCalendarWritesRemainUnverified() throws {
		let json =
			#"{"chatId":"main","turn":"01J0000000000000000000000A","attempt":"01J0000000000000000000000B","settlement":{"kind":"interrupted","partial":"","cause":"athleteStopped","saved":{"memorySections":0,"ledgerEvents":0,"planSaves":0,"calendarWrites":1}}}"#
		let decoded = RecordCodec.decode(
			kind: "turnSettled", version: 2, data: Data(json.utf8), civilDate: "1998-06-13",
			ulid: fixedUlid(1).rawValue)
		guard case .synced(.turnSettled(let body)) = try decoded.get(),
			case .interrupted(_, let cause, let saved) = body.settlement
		else {
			Issue.record("expected an interrupted turn")
			return
		}
		#expect(saved.calendarWrites == 1)
		#expect(saved.unverifiedCalendarWrites == 1)
		#expect(
			AthleteNotices.notice(for: cause, saved: saved, turn: body.turn)
				.key == Catalog.chatNoticeCalendarUnverified)
	}

	@Test(arguments: [0, 1, 2])
	func calendarConfirmationCountsSurviveSettlement(unverified: Int) throws {
		let saved = WriteSummary(
			memorySections: 0, ledgerEvents: 0, planSaves: 0, calendarWrites: 2,
			unverifiedCalendarWrites: unverified)
		let body = RecordBody.synced(
			.turnSettled(
				TurnSettledBody(
					chatId: .main, turn: TurnID(ulid: fixedUlid(1)),
					attempt: AttemptID(ulid: fixedUlid(2)),
					settlement: .interrupted(partial: "", cause: .athleteStopped, saved: saved))))
		let encoded = try RecordCodec.encode(body)
		let decoded = RecordCodec.decode(
			kind: "turnSettled", version: encoded.version, data: encoded.data,
			civilDate: "1998-06-13", ulid: fixedUlid(3).rawValue)
		#expect(try decoded.get() == body)
		#expect(
			AthleteNotices.notice(for: .athleteStopped, saved: saved, turn: nil).key
				== (unverified == 0
					? Catalog.chatTurnInterruptedSomeSaved : Catalog.chatNoticeCalendarUnverified))
	}
}
