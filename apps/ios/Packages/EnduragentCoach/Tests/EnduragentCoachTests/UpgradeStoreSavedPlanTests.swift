import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

extension SwiftDataSuites.UpgradeStoreTests {
	@Test func buildD6f89d9bKeepsEveryRowAndASavedPlanCommittedIntoItReadsBackAfterARelaunch()
		async throws
	{
		let plan = try #require(
			try PlanObjectParityTests.planObjects().first { $0.id == "plan-object/0026" }?
				.input.objectFields["plan"])
		let (root, synced, local, committed) = try await Self.commitSavedPlan(plan)

		let relaunched = try UpgradeStore(reopening: root, device: Self.milestoneFourDevice)
		let syncedAfter = try await relaunched.log.fetch(RecordQuery(scope: .everySynced))
		let localAfter = try await relaunched.log.fetch(RecordQuery(scope: .everyDeviceLocal))

		#expect(syncedAfter.skipped.isEmpty)
		#expect(localAfter.skipped.isEmpty)
		#expect(syncedAfter.records.count == synced.count + 1)
		for record in synced + [committed] {
			#expect(syncedAfter.records.first { $0.ulid == record.ulid } == record)
		}
		#expect(localAfter.records == local)
		let saved = try #require(SavedPlans(owned: syncedAfter.records).newest)
		#expect(saved == (try PlanDocument.parse(arguments: .object(["plan": plan]))))
		#expect(saved.value == plan)
	}

	private static func commitSavedPlan(_ plan: JSONValue) async throws
		-> (root: URL, synced: [AthleteRecord], local: [AthleteRecord], committed: AthleteRecord)
	{
		let store = try UpgradeStore(
			"waiting-review", folder: milestoneFourFolder, device: milestoneFourDevice)
		let synced = try await store.log.fetch(RecordQuery(scope: .everySynced))
		let local = try await store.log.fetch(RecordQuery(scope: .everyDeviceLocal))
		#expect(synced.skipped.isEmpty)
		#expect(local.skipped.isEmpty)
		#expect(!synced.records.isEmpty)
		#expect(!local.records.isEmpty)
		guard case .synced(let body) = try SavedPlanRows.body(plan) else {
			throw PlanFixtureFailure(description: "the codec read a saved plan as another locality")
		}
		let clock = milestoneFiveClock
		let ledger = Ledger(log: store.log, clock: clock, diagnostics: DiagnosticsLog(clock: clock))
		let committed = try await ledger.commit(synced: [body], stamp: testStamp())
		return (store.root, synced.records, local.records, try #require(committed.first))
	}
}
