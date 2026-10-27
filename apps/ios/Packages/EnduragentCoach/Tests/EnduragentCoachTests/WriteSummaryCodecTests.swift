import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

@Suite struct WriteSummaryCodecTests {
	@Test func confirmedCalendarSettlementMatchesGoldenBytes() throws {
		let golden = Data(try fixture("confirmed-calendar-settlement", ext: "json").utf8)
		let body = RecordBody.synced(
			.turnSettled(
				TurnSettledBody(
					chatId: .main, turn: TurnID(ulid: fixedUlid(1)),
					attempt: AttemptID(ulid: fixedUlid(2)),
					settlement: .interrupted(
						partial: "", cause: .athleteStopped,
						saved: WriteSummary(
							memorySections: 0, ledgerEvents: 0, planConfirmations: 0,
							calendarWrites: 1,
							unverifiedCalendarWrites: 0)))))
		let encoded = try RecordCodec.encode(body)
		#expect(encoded.version == 4)
		#expect(encoded.data == golden)
		let decoded = RecordCodec.decode(
			kind: "turnSettled", version: 2, data: golden,
			civilDate: "1998-06-13", ulid: fixedUlid(3).rawValue)
		#expect(try decoded.get() == body)
	}

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

	@Test func aMilestone4PlanSavesCountDecodesIntoPlanConfirmationsAndEncodesBack() throws {
		let json =
			#"{"chatId":"main","turn":"01J0000000000000000000000A","attempt":"01J0000000000000000000000B","settlement":{"kind":"interrupted","partial":"","cause":"processEnded","saved":{"memorySections":0,"ledgerEvents":0,"planSaves":1,"calendarWrites":0}}}"#
		let decoded = try RecordCodec.decode(
			kind: "turnSettled", version: 2, data: Data(json.utf8), civilDate: "1998-06-13",
			ulid: fixedUlid(1).rawValue
		).get()
		guard case .synced(.turnSettled(let body)) = decoded,
			case .interrupted(_, .processEnded, let saved) = body.settlement
		else {
			Issue.record("expected a turn interrupted by the process ending, got \(decoded)")
			return
		}
		#expect(saved.planConfirmations == 1)
		let encoded = try JSONValue.parse(
			String(decoding: try RecordCodec.encode(decoded).data, as: UTF8.self))
		#expect(
			encoded.objectFields["settlement"]?.objectFields["saved"]
				== .object([
					"memorySections": .number(0), "ledgerEvents": .number(0),
					"planSaves": .number(1), "calendarWrites": .number(0),
					"unverifiedCalendarWrites": .number(0),
				]))
	}

	@Test func aSettledRowKeepsItsPlanCauseAndAnUnknownCauseMakesItMalformed() throws {
		let settled = TurnSettledBody(
			chatId: .main, turn: TurnID(ulid: fixedUlid(1)), attempt: AttemptID(ulid: fixedUlid(2)),
			settlement: .replied(.model("Ready."), lineage: nil), planSaveNotPrepared: .notSaved)
		let encoded = try RecordCodec.encode(.synced(.turnSettled(settled)))
		let text = String(decoding: encoded.data, as: UTF8.self)
		#expect(text.contains(#""planSaveNotPrepared":"notSaved""#))
		func decode(_ text: String) -> Result<RecordBody, SkippedRow> {
			RecordCodec.decode(
				kind: "turnSettled", version: encoded.version, data: Data(text.utf8),
				civilDate: "1998-06-13", ulid: fixedUlid(3).rawValue)
		}
		#expect(try decode(text).get() == .synced(.turnSettled(settled)))
		var withoutKey = settled
		withoutKey.planSaveNotPrepared = nil
		#expect(
			try decode(
				text.replacingOccurrences(of: #","planSaveNotPrepared":"notSaved""#, with: "")
			)
			.get() == .synced(.turnSettled(withoutKey)))
		#expect(
			decode(text.replacingOccurrences(of: #""notSaved""#, with: #""lostInTransit""#))
				== .failure(.malformed(kind: "turnSettled", ulid: fixedUlid(3).rawValue)))
	}

	@Test(arguments: [0, 1, 2])
	func calendarConfirmationCountsSurviveSettlement(unverified: Int) throws {
		let saved = WriteSummary(
			memorySections: 0, ledgerEvents: 0, planConfirmations: 0, calendarWrites: 2,
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
