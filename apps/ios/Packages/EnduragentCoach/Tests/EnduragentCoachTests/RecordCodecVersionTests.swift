import EnduragentCoachFixtures
import Foundation
import SwiftData
import Testing

@testable import EnduragentCoach

extension SwiftDataSuites {
	@Suite struct RecordCodecVersionTests {
		static let milestoneFourBodyVersion = 6
		static let offlineNoticeBodyVersion = 7

		let phone = DeviceID(rawValue: "plan-shortcut-phone")

		@Test func aPlanMessageIsStoredAtVersion7AndEveryOtherUserMessageAtVersion4()
			async throws
		{
			let root = try TestTemporaryFolders.make()
			let log = try makeSwiftDataLog(deviceId: phone, directory: root)
			let commands: [SlashCommand?] = [nil] + SlashCommand.allCases
			let records = commands.enumerated().map { index, command in
				storedRecord(
					device: phone, wall: Int64(index + 1), ulid: fixedUlid(index + 1),
					body: .synced(
						.userMessage(
							UserMessageBody(
								chatId: .main, turn: TurnID(ulid: fixedUlid(100 + index)),
								fragment: 0, draft: DraftID(),
								athleteText: (command?.rawValue ?? "Thursday?")
									+ " for my gran fondo in June",
								slash: command))))
			}

			try await log.append(records, locality: .synced)

			let rows = try ModelContext(
				try ModelContainerHandle.withoutCloudKit(
					storeURL: root.appending(path: "synced.store")
				)
				.container
			).fetch(FetchDescriptor<StoredAthleteRecord>())
			let versions = Dictionary(uniqueKeysWithValues: rows.map { ($0.ulid, $0.bodyVersion) })
			let planUlid = try #require(
				records.first { record in
					guard case .synced(.userMessage(let body)) = record.body else { return false }
					return body.slash == .plan
				}?.ulid.rawValue)
			#expect(rows.count == commands.count)
			#expect(rows.allSatisfy { $0.kind == SyncedKind.userMessage.rawValue })
			#expect(versions[planUlid] == 7)
			#expect(
				versions.filter { $0.key != planUlid }.values.sorted()
					== Array(repeating: 4, count: commands.count - 1))
			#expect(
				rows.filter { $0.bodyVersion > Self.milestoneFourBodyVersion }.map(\.ulid)
					== [planUlid])
			let read = try await log.fetch(RecordQuery(scope: .synced([.userMessage])))
			#expect(read.skipped.isEmpty)
			#expect(Set(read.records.map(\.ulid)) == Set(records.map(\.ulid)))
			for record in records {
				#expect(read.records.first { $0.ulid == record.ulid } == record)
			}
		}

		@Test func aBuildBeforeTheNoConnectionNoticeSkipsOnlyNoConnectionSettlementsAsNewer()
			async throws
		{
			let root = try TestTemporaryFolders.make()
			let log = try makeSwiftDataLog(deviceId: phone, directory: root)
			let failures: [CoachFailure] = [
				.model(.providerDown(.noConnection)),
				.model(.accessUnavailable(.trainingIdentityUnverified(.noConnection))),
				.model(.providerDown(.network)),
				.model(.accessUnavailable(.trainingIdentityUnverified(.temporarilyUnavailable))),
			]
			let settled = failures.enumerated().map { index, failure in
				TurnSettledBody(
					chatId: .main, turn: TurnID(ulid: fixedUlid(100 + index)),
					attempt: AttemptID(ulid: fixedUlid(200 + index)),
					settlement: .failed(failure, saved: .none))
			}
			let records =
				settled.enumerated().map { index, body in
					storedRecord(
						device: phone, wall: Int64(index + 1), ulid: fixedUlid(index + 1),
						body: .synced(.turnSettled(body)))
				} + [
					storedRecord(
						device: phone, wall: 10, ulid: fixedUlid(10),
						body: .deviceLocal(.pendingSettlement(settled[0]))),
					storedRecord(
						device: phone, wall: 11, ulid: fixedUlid(11),
						body: .deviceLocal(.pendingSettlement(settled[2]))),
				]

			try await log.append(Array(records.prefix(4)), locality: .synced)
			try await log.append(Array(records.suffix(2)), locality: .deviceLocal)

			let rows = try ["synced.store", "local.store"].flatMap { file in
				try ModelContext(
					try ModelContainerHandle.withoutCloudKit(
						storeURL: root.appending(path: file)
					)
					.container
				).fetch(FetchDescriptor<StoredAthleteRecord>())
			}
			let skipped = rows.filter { $0.bodyVersion > Self.offlineNoticeBodyVersion }
			#expect(rows.count == records.count)
			#expect(
				Set(skipped.map(\.ulid))
					== Set([fixedUlid(1), fixedUlid(2), fixedUlid(10)].map(\.rawValue)))
			let synced = try await log.fetch(RecordQuery(scope: .synced([.turnSettled])))
			let local = try await log.fetch(
				RecordQuery(scope: .deviceLocal([.pendingSettlement])))
			#expect(synced.skipped.isEmpty && local.skipped.isEmpty)
			let read = synced.records + local.records
			#expect(read.count == records.count)
			for record in records {
				#expect(read.first { $0.ulid == record.ulid } == record)
			}
		}
	}
}
