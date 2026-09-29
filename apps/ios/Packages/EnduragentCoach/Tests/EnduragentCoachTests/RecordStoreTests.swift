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

		@Test func faultingFixtureRejectsTheNamedKindAndStillSavesOtherKinds() async throws {
			let fixture = try RecordStore.fixture(directory: directory, deviceId: device)
			let coach = coach(fixture.store)
			fixture.faults.failAppends(ofKind: "languagePreference")
			await #expect(throws: PreferenceWriteFailure.notSaved) {
				try await coach.setLanguage(.fixed(.fr))
			}
			#expect(await coach.languagePreference() == .automatic)
			let session = try SessionSettings.npmDefaults.replacing(.dailyResetHour, with: "6")
			try await coach.setSession(session)
			let status = await coach.status()
			#expect(status.session == session)
			let snapshot = try await coach.recordSyncProbe().snapshot()
			#expect(snapshot.counts.contains { $0.kind == "sessionSettings" && $0.count == 1 })
			#expect(!snapshot.counts.contains { $0.kind == "languagePreference" })
		}

		private func coach(_ store: RecordStore) -> Coach {
			Coach(
				sport: .cycling,
				ports: CoachPorts(
					records: store, secrets: keyedSecrets(),
					models: .scripted(FakeModelTransport()),
					training: .fake { _, _ in FakeIntervalsClient(athleteName: "Ada", ftp: 250) },
					credits: .fake(FakeCreditsClient()), host: ImmediateExecutionHost(),
					clock: FixedClock(
						now: "1998-06-13T08:00:00+02:00", timeZone: "Europe/Amsterdam")),
				builtInModel: testModel, deviceLanguage: .en, coalescing: quickWindow)
		}
	}
}
