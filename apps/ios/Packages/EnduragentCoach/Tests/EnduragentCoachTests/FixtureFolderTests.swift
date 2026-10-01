import EnduragentCoach
import EnduragentCoachFixtures
import Foundation
import Testing

struct FixtureFolderTests {
	@Test func cleanupWaitsForTheStoreOwnerBeforeRemovingItsFolder() async throws {
		let folder = try FixtureFolder(
			directory: FileManager.default.temporaryDirectory.appending(
				path: "enduragent-folder-\(UUID().uuidString)", directoryHint: .isDirectory))
		let held = Gate()
		let releasing = Gate()
		let owner = Task {
			try await FixtureFolder.$current.withValue(folder) {
				let fixture = try FixtureRecordStore(
					directory: folder.directory, deviceId: DeviceID())
				await held.wait()
				withExtendedLifetime(fixture) {}
			}
		}
		await held.waitUntilParked()
		let cleanup = Task {
			try await folder.cleanup {
				releasing.release()
				try await owner.value
			}
		}
		await releasing.wait()
		#expect(
			FileManager.default.fileExists(atPath: folder.directory.path),
			"Fixture cleanup removed the folder while its store owner was held open")
		held.release()
		try await cleanup.value
		#expect(!FileManager.default.fileExists(atPath: folder.directory.path))
	}

	@Test func cleanupPropagatesTheRemovalError() async throws {
		let folder = try FixtureFolder(
			directory: FileManager.default.temporaryDirectory.appending(
				path: "enduragent-folder-\(UUID().uuidString)", directoryHint: .isDirectory))
		try FileManager.default.removeItem(at: folder.directory)
		await #expect(throws: CocoaError.self) {
			try await folder.cleanup {}
		}
	}

	@Test(.timeLimit(.minutes(1)))
	func cleanupWaitsForEveryStoreOpenedInTheFolder() async throws {
		let folder = try FixtureFolder(
			directory: FileManager.default.temporaryDirectory.appending(
				path: "enduragent-folder-\(UUID().uuidString)", directoryHint: .isDirectory))
		let first = Gate()
		let second = Gate()
		let owner = Task {
			try await FixtureFolder.$current.withValue(folder) {
				var stores = try (0..<2).map { _ in
					try FixtureRecordStore(directory: folder.directory, deviceId: DeviceID())
				}
				await first.wait()
				stores.removeFirst()
				await second.wait()
				withExtendedLifetime(stores) {}
			}
		}
		await first.waitUntilParked()
		let cleanup = Task { try await folder.cleanup {} }
		var waiting = folder.waitingForStores.makeAsyncIterator()
		try #require(await waiting.next() != nil)
		#expect(FileManager.default.fileExists(atPath: folder.directory.path))
		first.release()
		try #require(await waiting.next() != nil)
		#expect(FileManager.default.fileExists(atPath: folder.directory.path))
		second.release()
		try await owner.value
		try await cleanup.value
		#expect(!FileManager.default.fileExists(atPath: folder.directory.path))
	}
}
