import EnduragentCoach
import EnduragentCoachFixtures
import Foundation
import SwiftData
import Testing

struct FixtureFolderTests {
	@Test(.timeLimit(.minutes(1)))
	func cleanupFailsWithinSecondsWhenAStoreOwnerIsNotReleased() async throws {
		let folder = try FixtureFolder(
			directory: FileManager.default.temporaryDirectory.appending(
				path: "enduragent-folder-\(UUID().uuidString)", directoryHint: .isDirectory))
		let opened = AsyncStream<Void>.makeStream()
		let owner = Task {
			try await FixtureFolder.$current.withValue(folder) {
				let fixture = try FixtureRecordStore(
					directory: folder.directory, deviceId: DeviceID())
				opened.continuation.finish()
				try await Task.sleep(for: .seconds(6))
				withExtendedLifetime(fixture) {}
			}
		}
		try #require(
			try await beforeDeadline(within: .seconds(5)) {
				for await _ in opened.stream {}
				return true
			} == true,
			"The fixture store did not open within five seconds")
		await #expect(throws: (any Error).self) {
			try await folder.cleanup {}
		}
		#expect(FileManager.default.fileExists(atPath: folder.directory.path))
		try await owner.value
		if FileManager.default.fileExists(atPath: folder.directory.path) {
			try await folder.cleanup {}
		}
	}

	@Test(.timeLimit(.minutes(1)))
	func cleanupWaitsForTheStoreOwnerBeforeRemovingItsFolder() async throws {
		try await checkCleanupWaitsForTheStoreOwner()
	}

	@Test(.timeLimit(.minutes(1)))
	func cleanupReportsAStoreOpenFailure() async throws {
		await #expect(throws: SwiftDataError.self) {
			try await checkCleanupWaitsForTheStoreOwner(unreadable: true)
		}
	}

	private func checkCleanupWaitsForTheStoreOwner(unreadable: Bool = false) async throws {
		let folder = try FixtureFolder(
			directory: FileManager.default.temporaryDirectory.appending(
				path: "enduragent-folder-\(UUID().uuidString)", directoryHint: .isDirectory))
		let held = Gate()
		let releasing = Gate()
		let completed: Void? = try await beforeDeadline(within: .seconds(5)) {
			try await withTaskCancellationHandler {
				try await withThrowingTaskGroup(of: Void.self) { group in
					defer {
						held.release()
						releasing.release()
						group.cancelAll()
					}
					group.addTask {
						try await FixtureFolder.$current.withValue(folder) {
							let fixture = try FixtureRecordStore(
								directory: folder.directory, deviceId: DeviceID(),
								unreadable: unreadable)
							try await held.waitUnlessCancelled()
							withExtendedLifetime(fixture) {}
						}
					}
					group.addTask { await held.waitUntilParked() }
					try await group.next()
					try Task.checkCancellation()
					group.addTask {
						try await folder.cleanup { releasing.release() }
					}
					try await releasing.waitUnlessCancelled()
					#expect(
						FileManager.default.fileExists(atPath: folder.directory.path),
						"Fixture cleanup removed the folder while its store owner was held open")
					held.release()
					while try await group.next() != nil {}
				}
			} onCancel: {
				held.release()
				releasing.release()
			}
		}
		try #require(completed != nil, "Fixture cleanup did not finish within five seconds")
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
		let completed: Void? = try await beforeDeadline(within: .seconds(5)) {
			try await withTaskCancellationHandler {
				try await withThrowingTaskGroup(of: Void.self) { group in
					defer {
						first.release()
						second.release()
						group.cancelAll()
					}
					group.addTask {
						try await FixtureFolder.$current.withValue(folder) {
							var stores = try (0..<2).map { _ in
								try FixtureRecordStore(
									directory: folder.directory, deviceId: DeviceID())
							}
							try await first.waitUnlessCancelled()
							stores.removeFirst()
							try await second.waitUnlessCancelled()
							withExtendedLifetime(stores) {}
						}
					}
					group.addTask { await first.waitUntilParked() }
					try await group.next()
					try Task.checkCancellation()
					group.addTask { try await folder.cleanup {} }
					var waiting = folder.waitingForStores.makeAsyncIterator()
					try #require(await waiting.next() != nil)
					#expect(FileManager.default.fileExists(atPath: folder.directory.path))
					first.release()
					try #require(await waiting.next() != nil)
					#expect(FileManager.default.fileExists(atPath: folder.directory.path))
					second.release()
					while try await group.next() != nil {}
				}
			} onCancel: {
				first.release()
				second.release()
			}
		}
		try #require(completed != nil, "Fixture cleanup did not finish within five seconds")
		#expect(!FileManager.default.fileExists(atPath: folder.directory.path))
	}
}
