import EnduragentCoachFixtures
import Foundation
import SwiftData
import Testing

@testable import EnduragentCoach

extension SwiftDataSuites {
	@Suite struct SavedPlanTests {
		let phone = DeviceID(rawValue: "plan-phone")

		@Test func aSavedPlanIsStoredAtBodyVersion7AndReadsBackWhole() async throws {
			let root = try TestTemporaryFolders.make()
			let log = try makeSwiftDataLog(deviceId: phone, directory: root)
			let body = try SavedPlanRows.body(PlanDocumentTests.base)
			let record = storedRecord(device: phone, wall: 1, ulid: fixedUlid(9), body: body)

			try await log.append([record], locality: .synced)

			let read = try await log.fetch(RecordQuery(scope: .synced([SavedPlans.kind])))
			#expect(read.skipped.isEmpty)
			#expect(read.records == [record])
			#expect(
				SavedPlans(owned: read.records).newest?.value == PlanDocumentTests.base)
			let rows = try ModelContext(
				try ModelContainerHandle.withoutCloudKit(
					storeURL: root.appending(path: "synced.store")
				)
				.container
			).fetch(FetchDescriptor<StoredAthleteRecord>())
			#expect(rows.map(\.bodyVersion) == [SavedPlanRows.version])
			#expect(rows.map(\.kind) == [SavedPlans.kind.rawValue])
		}

		@Test func aSavedPlanRowFromALaterBodyVersionIsSkippedAsNewer() async throws {
			let root = try TestTemporaryFolders.make()
			let log = try makeSwiftDataLog(deviceId: phone, directory: root)
			let record = storedRecord(
				device: phone, wall: 1, ulid: fixedUlid(9),
				body: try SavedPlanRows.body(PlanDocumentTests.base))
			let context = ModelContext(
				try ModelContainerHandle.withoutCloudKit(
					storeURL: root.appending(path: "synced.store")
				)
				.container)
			let row = try StoredAthleteRecord(record: record)
			row.bodyVersion = SavedPlanRows.version + 1
			context.insert(row)
			try context.save()

			let read = try await log.fetch(RecordQuery(scope: .synced([SavedPlans.kind])))

			#expect(read.records.isEmpty)
			#expect(
				read.skipped == [
					.newerVersion(
						kind: SavedPlans.kind.rawValue, version: 8, ulid: fixedUlid(9).rawValue)
				])
		}

		@Test func everyOtherKindKeepsTheBodyVersionItWasStoredAt() throws {
			let expected: [String: Int] = [
				"savedPlan": 7, "reviewOutcome": 6, "workoutReview": 6, "reviewPreparing": 6,
				"attemptQuestion": 5, "trainingIdentityObserved": 4, "userMessage": 4,
				"turnSettled": 4, "windowStart": 4, "compactionSummary": 4, "memorySection": 2,
				"dailyNote": 2, "ledgerEvent": 2, "journal": 2, "provenance": 2,
				"coachReplyLanguage": 2, "sessionSettings": 2, "languagePreference": 2,
				"openRouterKeyRejected": 2, "providerConsent": 2, "turnClaim": 2,
				"replyObserved": 2, "pendingSettlement": 2, "flushPending": 2, "flushSettled": 2,
			]
			let samples = try SwiftDataRecordLogTests().sampleBodies()

			let versions = try Dictionary(
				samples.map { ($0.kind, try RecordCodec.encode($0.body).version) },
				uniquingKeysWith: { first, _ in first })

			#expect(versions == expected)
			#expect(RecordCodec.currentBodyVersion == 7)
		}

		@Test func theSavedPlanIsTheNewestDecisionEvenWhenAnOlderDecisionLandedLater() throws {
			let older = try save("Older", id: 1, decided: 5, landed: 30)
			let newer = try save("Newer", id: 2, decided: 8, landed: 20)
			let tiedFirst = try save("Tied first", id: 3, decided: 3, landed: 10)
			let tiedSecond = try save("Tied second", id: 4, decided: 3, landed: 11)
			let memory = storedRecord(
				device: phone, wall: 40,
				body: .synced(.memorySection(MemorySectionBody(name: .person, content: "Ada"))))

			let plans = SavedPlans(owned: [older, memory, tiedSecond, newer, tiedFirst])

			#expect(plans.newest?.value.objectFields["name"] == .string("Newer"))
			#expect(
				SavedPlans(owned: [tiedSecond, tiedFirst]).newest?.value.objectFields["name"]
					== .string("Tied second"))
			#expect(
				SavedPlans(owned: [older]).newest?.value.objectFields["name"] == .string("Older"))
			#expect(SavedPlans(owned: [memory]).newest == nil)
		}

		@Test func aSecondRowWithAnIdAlreadySeenCountsOnce() throws {
			let first = try save("Base", id: 1, decided: 5, landed: 10)
			let replacement = try save("Build", id: 2, decided: 8, landed: 20)
			let again = try save("Base", id: 1, decided: 5, landed: 30, ulid: 7)

			let plans = SavedPlans(owned: [again, replacement, first])

			#expect(plans == SavedPlans(owned: [first, replacement]))
			#expect(plans != SavedPlans(owned: [again, replacement]))
			#expect(plans.newest?.value.objectFields["name"] == .string("Build"))
		}

		private func save(
			_ name: String, id: Int, decided: Int64, landed: Int64, ulid: Int? = nil
		) throws -> AthleteRecord {
			storedRecord(
				device: phone, wall: landed, ulid: fixedUlid(ulid ?? 100 + id),
				body: try SavedPlanRows.body(
					.object(["name": .string(name)]), id: id, confirmation: 50 + id,
					decided: HybridLogicalClock(wallMs: decided, logical: 0, deviceId: phone)))
		}
	}
}
