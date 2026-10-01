import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

extension SwiftDataSuites {
	@Suite struct ResetBoundaryPersistenceTests {
		@Test func skewedSendAfterPersistedResetSurvivesStoreReopen() async throws {
			let root = FileManager.default.temporaryDirectory.appending(
				path: "reset-boundary-\(UUID().uuidString)")
			try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
			let remoteLog = try open(root, device: DeviceID(rawValue: "phone-a"))
			let ahead = FixedClock(now: "1998-06-13T12:02:00+02:00", timeZone: "Europe/Amsterdam")
			try await seedHistory(remoteLog, clock: ahead, turns: 1, tokens: 40)
			let remote = await makeCoach(
				transport: FakeModelTransport(), store: remoteLog, clock: ahead)
			#expect(await remote.startNewConversation(in: .main) == .started(memory: .saved))
			await remote.lifecycle(.willTerminate)
			let localLog = try open(root, device: DeviceID(rawValue: "phone-b"))
			let behind = FixedClock(now: "1998-06-13T12:00:00+02:00", timeZone: "Europe/Amsterdam")
			let transport = FakeModelTransport()
			transport.respond = ScriptedReply.sequence(
				[.text("Current answer"), .finish(reason: .stop)], otherwise: transport.respond)
			let local = await makeCoach(transport: transport, store: localLog, clock: behind)
			_ = try #require(
				try await local.send(draft("Current question"), to: .main).acceptedTurn)
			try await waitForRecords(.synced([.turnSettled]), count: 2, in: localLog)
			#expect(await local.transcript(.main) == ["Current question", "Current answer"])
			await local.lifecycle(.willTerminate)
			let reopenedLog = try open(root, device: DeviceID(rawValue: "phone-b"))
			let reopened = await makeCoach(transport: transport, store: reopenedLog, clock: behind)
			#expect(await reopened.transcript(.main) == ["Current question", "Current answer"])
			let archive = try #require(try await reopened.history().first?.id)
			#expect(
				try await reopened.archivedConversation(archive)?.turns.map(\.athleteText) == [
					"Question 0"
				])
		}

		private func open(_ root: URL, device: DeviceID) throws -> SwiftDataRecordLog {
			SwiftDataRecordLog(
				deviceId: device,
				synced: try ModelContainerHandle.withoutCloudKit(
					storeURL: root.appending(path: "synced.store")),
				local: try ModelContainerHandle.withoutCloudKit(
					storeURL: root.appending(path: "local.store")))
		}
	}
}
