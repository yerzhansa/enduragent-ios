import EnduragentCoachFixtures
import Foundation
import SwiftData
import Testing

@testable import EnduragentCoach

extension SwiftDataSuites {
	@Suite struct PlanConfirmationRecordTests {
		let phone = PlanStepRows.phone
		let expiresAt = Date(timeIntervalSince1970: 899_165_400.25)
		let rows = PlanStepRows(confirmation: 1, turn: 20)

		@Test func everyChainStepRoundTripsThroughTheStoreAtBodyVersion7() async throws {
			let root = try TestTemporaryFolders.make()
			let log = try makeSwiftDataLog(deviceId: phone, directory: root)
			let athlete = try #require(IntervalsAthleteID(rawValue: "i12345"))
			let account = TrainingAccount.intervals(connection: ConnectionID(), athlete: athlete)
			let claimRow = try PlanClaimRow(
				savedPlan: 61, attempt: 62, for: PlanDocumentTests.base)
			let decision = AttemptID(ulid: fixedUlid(62))
			let bodies = [
				try rows.prepared(PlanDocumentTests.base, account: account, expiresAt: expiresAt),
				try rows.claimed(claimRow),
				try rows.saved(claimRow.claim.savedPlan),
				try rows.canceled(),
			]
			let causes: [RecordCause] =
				[.operation(.turn(rows.origin.turn), rows.origin.attempt)]
				+ Array(repeating: .operation(.planSave(rows.id), decision), count: 3)
			let records = zip(bodies, causes).enumerated().map { index, step in
				storedRecord(
					device: phone, wall: Int64(index + 1), ulid: fixedUlid(index + 1),
					cause: step.1, account: account, body: step.0)
			}
			for record in records {
				try await log.append([record], locality: .deviceLocal)
			}

			let read = try await log.fetch(RecordQuery.planChain(of: .main))
			let byTurn = try await log.fetch(
				RecordQuery(
					scope: .deviceLocal([PlanChain.kind]), chatId: .main, turn: rows.origin.turn))
			let otherChat = try await log.fetch(
				RecordQuery.planChain(of: try #require(ChatID(rawValue: "other"))))

			#expect(read.skipped.isEmpty)
			#expect(read.records == records)
			#expect(byTurn.records == records)
			#expect(otherChat.records.isEmpty)
			#expect(
				read.records.compactMap(PlanStepRecord.init).map(\.body.step) == [
					.prepared(
						PreparedPlanSave(
							document: try PlanDocument.parse(
								arguments: .object(["plan": PlanDocumentTests.base])),
							account: account, expiresAt: expiresAt)),
					.claimed(claimRow.claim), .saved(claimRow.claim.savedPlan), .canceled,
				])
			#expect(read.records.last?.cause == .operation(.planSave(rows.id), decision))
			let stored = try storedRows(in: root)
			#expect(stored.map(\.bodyVersion) == Array(repeating: PlanStepRows.version, count: 4))
			#expect(Set(stored.map(\.kind)) == [PlanChain.kind.rawValue])
			#expect(stored.last?.operation == "planSave:\(rows.id.ulid.rawValue)")
		}

		@Test func aPreparedStepWithAHandEditedDocumentIsSkippedAsMalformed() async throws {
			let root = try TestTemporaryFolders.make()
			let log = try makeSwiftDataLog(deviceId: phone, directory: root)
			let untouched = storedRecord(
				device: phone, wall: 1, ulid: fixedUlid(1),
				body: try rows.prepared(PlanDocumentTests.base, expiresAt: expiresAt))
			let edited = storedRecord(
				device: phone, wall: 2, ulid: fixedUlid(2),
				body: try PlanStepRows(confirmation: 2, turn: 30)
					.prepared(PlanDocumentTests.base, expiresAt: expiresAt))
			let context = ModelContext(
				try ModelContainerHandle.withoutCloudKit(
					storeURL: root.appending(path: "local.store")
				)
				.container)
			let editedRow = try StoredAthleteRecord(record: edited)
			let original = String(decoding: editedRow.body, as: UTF8.self)
			let changed = original.replacingOccurrences(of: "\"Base\\\"", with: "\"Bass\\\"")
			try #require(changed != original)
			editedRow.body = Data(changed.utf8)
			context.insert(try StoredAthleteRecord(record: untouched))
			context.insert(editedRow)
			try context.save()

			let read = try await log.fetch(RecordQuery.planChain(of: .main))

			#expect(read.records == [untouched])
			#expect(
				read.skipped == [
					.malformed(kind: PlanChain.kind.rawValue, ulid: fixedUlid(2).rawValue)
				])
		}

		@Test func aPlanSaveStampWhoseTailIsNotAULIDIsSkippedAsMalformed() async throws {
			let root = try TestTemporaryFolders.make()
			let log = try makeSwiftDataLog(deviceId: phone, directory: root)
			let context = ModelContext(
				try ModelContainerHandle.withoutCloudKit(
					storeURL: root.appending(path: "local.store")
				)
				.container)
			for (index, operation) in ["planSave:\(rows.id.ulid.rawValue)", "planSave:not-a-ulid"]
				.enumerated()
			{
				let row = try StoredAthleteRecord(
					record: storedRecord(
						device: phone, wall: Int64(index + 1), ulid: fixedUlid(index + 1),
						cause: .operation(.planSave(rows.id), AttemptID(ulid: fixedUlid(62))),
						body: try rows.canceled()))
				row.operation = operation
				context.insert(row)
			}
			try context.save()

			let read = try await log.fetch(RecordQuery.planChain(of: .main))

			#expect(
				read.records.map(\.cause) == [
					.operation(.planSave(rows.id), AttemptID(ulid: fixedUlid(62)))
				])
			#expect(
				read.skipped == [
					.malformed(kind: PlanChain.kind.rawValue, ulid: fixedUlid(2).rawValue)
				])
		}

		private func storedRows(in root: URL) throws -> [StoredAthleteRecord] {
			try ModelContext(
				try ModelContainerHandle.withoutCloudKit(
					storeURL: root.appending(path: "local.store")
				)
				.container
			).fetch(FetchDescriptor<StoredAthleteRecord>()).sorted { $0.hlcWallMs < $1.hlcWallMs }
		}
	}
}
