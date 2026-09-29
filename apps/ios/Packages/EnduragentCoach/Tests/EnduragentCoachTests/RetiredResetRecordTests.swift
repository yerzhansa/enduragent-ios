import Foundation
import SwiftData
import Testing

@testable import EnduragentCoach

@Suite struct RetiredResetRecordTests {
	let boundary = fixedUlid(3).rawValue

	func windowStart(_ reason: String) -> Result<RecordBody, SkippedRow> {
		RecordCodec.decode(
			kind: "windowStart", version: 2,
			data: Data(
				#"{"chatId":"main","firstIncludedUlid":"\#(boundary)","reason":"\#(reason)"}"#.utf8),
			civilDate: "1998-06-13", ulid: "row-window")
	}

	func flushPending(_ trigger: String) -> Result<RecordBody, SkippedRow> {
		RecordCodec.decode(
			kind: "flushPending", version: 2,
			data: Data(#"{"chatId":"main","trigger":"\#(trigger)","messageUlids":[]}"#.utf8),
			civilDate: "1998-06-13", ulid: "row-flush")
	}

	@Test func automaticBoundariesNoLongerDecode() {
		#expect(
			windowStart("reset:daily")
				== .failure(.malformed(kind: "windowStart", ulid: "row-window")))
		#expect(
			windowStart("reset:idle")
				== .failure(.malformed(kind: "windowStart", ulid: "row-window")))
		#expect(
			windowStart("reset:explicit:\(boundary)")
				== .success(
					.synced(
						.windowStart(
							WindowStartBody(
								chatId: .main, firstIncludedUlid: fixedUlid(3),
								reason: .reset(ResetID(ulid: fixedUlid(3))))))))
	}

	@Test func newConversationBoundariesKeepTheirStoredForm() throws {
		let body = RecordBody.synced(
			.windowStart(
				WindowStartBody(
					chatId: .main, firstIncludedUlid: fixedUlid(3),
					reason: .reset(ResetID(ulid: fixedUlid(3))))))
		let encoded = try RecordCodec.encode(body)
		let json = try #require(
			try JSONSerialization.jsonObject(with: encoded.data) as? [String: Any])
		#expect(json["reason"] as? String == "reset:explicit:\(boundary)")
		#expect(
			RecordCodec.decode(
				kind: "windowStart", version: encoded.version, data: encoded.data,
				civilDate: "1998-06-13", ulid: "row-window") == .success(body))
	}

	@Test func staleResetJobsNoLongerDecode() {
		#expect(
			flushPending("staleReset")
				== .failure(.malformed(kind: "flushPending", ulid: "row-flush")))
		guard case .success(.deviceLocal(.flushPending(let body))) = flushPending("explicitReset")
		else {
			Issue.record("an explicitReset job still decodes")
			return
		}
		#expect(body.trigger == .explicitReset)
	}
}

extension SwiftDataSuites {
	@Suite struct RetiredResetStoreTests {
		let phone = DeviceID(rawValue: "phone-a")
		let clock = FixedClock(now: "1998-06-13T12:00:00+02:00", timeZone: "Europe/Amsterdam")

		@Test func automaticallyArchivedTurnsFoldBackUntilANewConversation() async throws {
			let root = FileManager.default.temporaryDirectory.appending(
				path: "enduragent-retired-\(UUID().uuidString)", directoryHint: .isDirectory)
			try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
			let synced = root.appending(path: "synced.store")
			let turns = ["A", "B", "C", "D"].enumerated().map { index, name in
				(name, TurnID(ulid: fixedUlid(10 * (index + 1))))
			}
			var rows: [(record: AthleteRecord, reason: String?)] = []
			for (index, (name, turn)) in turns.enumerated() {
				let wall = Int64(10 * (index + 1))
				if index > 0 {
					let first = fixedUlid(10 * (index + 1))
					rows.append(
						(
							storedRecord(
								device: phone, wall: wall - 1,
								ulid: fixedUlid(10 * (index + 1) - 1),
								body: .synced(
									.windowStart(
										WindowStartBody(
											chatId: .main, firstIncludedUlid: first,
											reason: .reset(ResetID(ulid: first)))))),
							["reset:daily", nil, "reset:idle"][index - 1]
						))
				}
				rows.append(
					(
						storedRecord(
							device: phone, wall: wall, ulid: turn.ulid,
							body: .synced(sampleUser(chatId: .main, text: "\(name)?", turn: turn))),
						nil
					))
				rows.append(
					(
						storedRecord(
							device: phone, wall: wall + 1, ulid: fixedUlid(10 * (index + 1) + 1),
							body: .synced(sampleReply(chatId: .main, turn: turn, text: "\(name)."))),
						nil
					))
			}
			let context = ModelContext(
				try ModelContainerHandle.withoutCloudKit(storeURL: synced).container)
			for (record, reason) in rows {
				let row = try StoredAthleteRecord(record: record)
				if let reason {
					row.body = Data(
						#"{"chatId":"main","firstIncludedUlid":"\#(row.ulid)","reason":"\#(reason)"}"#
							.utf8)
				}
				context.insert(row)
			}
			try context.save()
			let log = SwiftDataRecordLog(
				deviceId: phone,
				synced: try ModelContainerHandle.withoutCloudKit(storeURL: synced),
				local: try ModelContainerHandle.withoutCloudKit(
					storeURL: root.appending(path: "local.store")))
			let coach = makeCoach(transport: FakeModelTransport(), store: log, clock: clock)
			#expect(await coach.transcript(.main) == ["C?", "C.", "D?", "D."])
			#expect(await coach.currentSnapshot(.main)?.opening == .continuing)
			let archived = try await coach.history()
			#expect(archived.map(\.reason) == [.newConversation])
			#expect(archived.first?.turns.compactMap(\.athleteText) == ["A?", "B?"])
			let skipped = coach.diagnostics.entries.compactMap { entry -> String? in
				guard case .skippedRecord(.malformed(kind: "windowStart", let ulid)) = entry.event
				else { return nil }
				return ulid
			}
			#expect(Set(skipped) == [fixedUlid(19).rawValue, fixedUlid(39).rawValue])
		}
	}
}
