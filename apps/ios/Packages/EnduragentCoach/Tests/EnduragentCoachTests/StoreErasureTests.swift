import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

extension SwiftDataSuites {
	@Suite struct StoreErasureTests {
		let phone = DeviceID(rawValue: "phone-a")
		let otherPhone = DeviceID(rawValue: "phone-b")

		@Test(arguments: RecordLogKind.allCases)
		func eraseDeletesEveryRowOfOneLocalityAcrossPages(kind: RecordLogKind) async throws {
			let log = try SwiftDataSuites.makeRecordLog(kind, deviceId: phone)
			let pages = SwiftDataRecordLog.erasePage * 2 + 1
			try await log.append(
				(0..<pages).map { index in
					storedRecord(
						device: index.isMultiple(of: 2) ? phone : otherPhone, wall: Int64(index),
						body: .synced(sampleUser(chatId: .main, text: "message \(index)")))
				}, locality: .synced)
			try await log.append(
				[storedRecord(device: phone, wall: 1, body: .deviceLocal(sampleLocal()))],
				locality: .deviceLocal)

			#expect(try await log.erase(.synced, writtenBefore: nil) == pages)
			#expect(try await log.fetch(RecordQuery(scope: .everySynced)).records.isEmpty)
			#expect(try await log.fetch(RecordQuery(scope: .everyDeviceLocal)).records.count == 1)
			#expect(try await log.erase(.synced, writtenBefore: nil) == 0)
			#expect(try await log.erase(.deviceLocal, writtenBefore: nil) == 1)
			#expect(try await log.fetch(RecordQuery(scope: .everyDeviceLocal)).records.isEmpty)
		}

		@Test(arguments: RecordLogKind.allCases)
		func eraseWrittenBeforeACutoffKeepsLaterRows(kind: RecordLogKind) async throws {
			let log = try SwiftDataSuites.makeRecordLog(kind, deviceId: phone)
			try await log.append(
				[
					storedRecord(
						device: otherPhone, wall: 1_999,
						body: .synced(sampleUser(chatId: .main, text: "returning"))),
					storedRecord(
						device: otherPhone, wall: 2_000,
						body: .synced(sampleUser(chatId: .main, text: "written after"))),
				], locality: .synced)

			let cutoff = Date(timeIntervalSince1970: 2)
			#expect(try await log.erase(.synced, writtenBefore: cutoff) == 1)
			let left = try await log.fetch(RecordQuery(scope: .everySynced)).records
			#expect(left.map(messageText) == ["written after"])
		}

		@Test func deleteEverythingRemovesEveryKeychainItemOfTheService() throws {
			let backing = FixtureSecretStoreBacking(items: [
				"openRouterKey": Data("legacy-credits-key".utf8),
				"appAccountToken": Data(UUID().uuidString.utf8),
			])
			let store = ICloudKeychainStore(backing: backing)
			try store.storeIntervalsConnection(testConnection)
			let generation = OpenRouterCredentialRef.generation(UUID())
			try store.storeOpenRouterAccountKey("generation-key", at: generation)
			try store.prepareAccessSelection(SavedAccessReference(.credits), at: UUID())

			try store.deleteEverything()
			try store.deleteEverything()

			#expect(try store.creditsAccount() == nil)
			#expect(try store.intervalsConnection() == nil)
			#expect(try store.accessSelection() == nil)
			#expect(try store.openRouterAccountKey(at: generation) == nil)
			#expect(try backing.copy(account: "openRouterKey") == nil)
		}

		@Test func eraseFilesRemovesTheJournalTheKeptNoteTheCatalogAndSharedFiles() throws {
			let directory = try TestTemporaryFolders.make()
			try FileManager.default.createDirectory(
				at: directory, withIntermediateDirectories: true)
			let support = SupportService.fixture(directory: directory, app: .fixture)
			let cache = FileModelCatalogCache(directory: directory)
			try Data("{}\n".utf8).write(to: directory.appending(path: "diagnostics.jsonl"))
			try Data("{}\n".utf8).write(to: directory.appending(path: "diagnostics.jsonl.next"))
			try support.keptNotes.save(
				KeptNote(note: .first(try FeedbackText(validating: "Kept note")), phase: .ready))
			try cache.replaceAtomically(.fixture)
			_ = try support.shareFolder.write(
				Data("file".utf8), named: "diagnostics.json", id: fixedUlid(7))

			try support.eraseFiles()
			try cache.erase()
			try support.eraseFiles()
			try cache.erase()

			let left = try FileManager.default.contentsOfDirectory(atPath: directory.path)
			#expect(left == [support.shareFolder.directory.lastPathComponent])
			#expect(
				try FileManager.default.contentsOfDirectory(
					atPath: support.shareFolder.directory.path
				).isEmpty)
		}

		@Test func deviceDefaultsEraseEveryAppKeyAndLeaveTheMarkerAsAsked() throws {
			let suite = "icu.enduragent.tests.\(UUID().uuidString)"
			let defaults = try #require(UserDefaults(suiteName: suite))
			defer { defaults.removePersistentDomain(forName: suite) }
			let device = DeviceDefaults(suiteName: suite)
			defaults.set("phone-a", forKey: "enduragent.deviceId")
			defaults.set(true, forKey: "enduragent.onboardingCompleted")
			defaults.set("draft", forKey: "enduragent.draft.main.text")
			defaults.set("kept", forKey: "other.setting")
			let began = Date(timeIntervalSince1970: 1_000)
			let local = LocalErasure(credits: .kept, iCloud: .erasedUnconfirmed)
			device.mark(.running(.erasingLocally(local), began: began))
			#expect(device.erasureRun?.progress == .erasingLocally(local))
			#expect(device.erasureRun?.began == began)

			device.erase(keeping: .iCloudPending(began: began))

			#expect(device.erasure == .iCloudPending(began: began))
			#expect(device.erasureRun == nil)
			#expect(defaults.string(forKey: "enduragent.deviceId") == nil)
			#expect(defaults.object(forKey: "enduragent.onboardingCompleted") == nil)
			#expect(defaults.string(forKey: "enduragent.draft.main.text") == nil)
			#expect(defaults.string(forKey: "other.setting") == "kept")

			device.erase(keeping: nil)
			#expect(device.erasure == nil)
		}
	}
}
