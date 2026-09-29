import Foundation
import Testing

@testable import EnduragentCoach

extension SwiftDataSuites {
	@Suite struct RecordStoreTests {
		let device = DeviceID(rawValue: "record-store-phone")
		let directory = FileManager.default.temporaryDirectory.appending(
			path: "enduragent-record-store-\(UUID().uuidString)", directoryHint: .isDirectory)

		@Test func inMemoryHandleKeepsPreferencesAcrossCoachInstances() async throws {
			let store = RecordStore.inMemory(deviceId: device)
			try await coach(store).setLanguage(.fixed(.fr))
			#expect(await coach(store).languagePreference() == .fixed(.fr))
			#expect(await coach(store).recordSyncProbe().deviceId == device)
		}

		@Test func fixtureReopensTheExistingStoreFilesAndDevice() async throws {
			let first = try RecordStore.fixture(directory: directory, deviceId: device)
			try await coach(first.store).setLanguage(.fixed(.fr))
			let reopened = try RecordStore.fixture(directory: directory, deviceId: device)
			#expect(await coach(reopened.store).languagePreference() == .fixed(.fr))
			#expect(await coach(reopened.store).recordSyncProbe().deviceId == device)
			let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
			#expect(files.contains("synced-records.store"))
			#expect(files.contains("local-records.store"))
		}

		@Test func unreadableFixtureThrowsAtStoreConstruction() throws {
			#expect(throws: (any Error).self) {
				try RecordStore.fixture(directory: directory, deviceId: device, unreadable: true)
			}
		}

		private func coach(_ store: RecordStore) -> Coach {
			Coach(
				sport: .cycling,
				ports: CoachPorts(
					records: store, secrets: keyedSecrets(), models: .scripted(FakeModelTransport()),
					training: .fake { _, _ in FakeIntervalsClient(athleteName: "Ada", ftp: 250) },
					credits: .fake(FakeCreditsClient()), host: ImmediateExecutionHost(),
					clock: FixedClock(now: "1998-06-13T08:00:00+02:00", timeZone: "Europe/Amsterdam")),
				builtInModel: testModel, deviceLanguage: .en, coalescing: quickWindow)
		}
	}
}
