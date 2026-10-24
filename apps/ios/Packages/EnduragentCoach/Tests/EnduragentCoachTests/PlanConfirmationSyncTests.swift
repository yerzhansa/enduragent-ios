import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

extension SwiftDataSuites {
	@Suite struct PlanConfirmationSyncTests {
		@Test func aSecondDeviceSeesTheSavedPlanInItsPromptAndPlanLoadButNoCard() async throws {
			let directory = try TestTemporaryFolders.make()
			let synced = try ModelContainerHandle.withoutCloudKit(
				storeURL: directory.appending(path: ModelContainerHandle.syncedStoreFileName))
			let device = { (name: String) in
				SwiftDataRecordLog(
					deviceId: DeviceID(rawValue: name), synced: synced,
					local: try ModelContainerHandle.deviceLocal(
						directory: directory.appending(path: name)))
			}
			let phone = PlanTurns()
			let pad = PlanTurns(clock: phone.clock)
			let phoneLog = try device("phone")
			let phoneCoach = await phone.coach(over: phoneLog)
			let token = try await phone.prepareAndArm(PlanTurns.baseBuild, on: phoneCoach)
			#expect(await phoneCoach.decide(.save(token), in: .main) == .saved)

			let padCoach = await pad.coach(over: try device("pad"))

			#expect(try await pad.planLoad(on: padCoach) == PlanTurns.baseBuild)
			let request = try #require(pad.transport.requests.first)
			#expect(try MemoryProbe.systemText(in: request).contains("- Name: Base Build"))
			#expect(try await pad.cards(on: padCoach).isEmpty)
			#expect(try await SavedPlanRows.stored(in: phoneLog).count == 1)
			#expect(try await phone.cards(on: phoneCoach).map(\.state) == [.saved])
		}
	}
}
