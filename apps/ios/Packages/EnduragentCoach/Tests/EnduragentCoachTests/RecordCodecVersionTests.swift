import EnduragentCoachFixtures
import Foundation
import SwiftData
import Testing

@testable import EnduragentCoach

extension SwiftDataSuites {
	@Suite struct RecordCodecVersionTests {
		static let milestoneFourBodyVersion = 6

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
	}
}
