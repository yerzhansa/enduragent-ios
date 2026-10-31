import Foundation
import SwiftData
import Synchronization

extension ModelContainerHandle {
	package static let cloudKitContainerIdentifier = "iCloud.icu.enduragent.ios"
	package static let syncedStoreFileName = "synced-records.store"
	package static let localStoreFileName = "local-records.store"

	package static func applicationSupportDirectory() throws -> URL {
		let root = try FileManager.default.url(
			for: .applicationSupportDirectory,
			in: .userDomainMask,
			appropriateFor: nil,
			create: true
		)
		let directory = root.appending(path: "EnduragentCoach", directoryHint: .isDirectory)
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		return directory
	}

	package static func syncedCloudKit(directory: URL) throws -> ModelContainerHandle {
		try make(
			name: "synced-records",
			storeURL: directory.appending(path: syncedStoreFileName),
			cloudKitDatabase: .private(cloudKitContainerIdentifier)
		)
	}

	package static func deviceLocal(directory: URL) throws -> ModelContainerHandle {
		let storeURL = directory.appending(path: localStoreFileName).standardizedFileURL
			.resolvingSymlinksInPath()
		return try deviceLocalHandles.withLock { handles in
			if let handle = handles[storeURL]?.handle { return handle }
			let handle = try make(
				name: "local-records", storeURL: storeURL, cloudKitDatabase: .none)
			handles[storeURL] = HeldHandle(handle)
			return handle
		}
	}

	private static let deviceLocalHandles = Mutex<[URL: HeldHandle]>([:])

	package static func withoutCloudKit(storeURL: URL) throws -> ModelContainerHandle {
		try make(
			name: storeURL.lastPathComponent,
			storeURL: storeURL,
			cloudKitDatabase: .none
		)
	}

	private static func make(
		name: String,
		storeURL: URL,
		cloudKitDatabase: ModelConfiguration.CloudKitDatabase
	) throws -> ModelContainerHandle {
		let schema = Schema([StoredAthleteRecord.self])
		let parent = storeURL.deletingLastPathComponent()
		try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
		let configuration = ModelConfiguration(
			name,
			schema: schema,
			url: storeURL,
			cloudKitDatabase: cloudKitDatabase
		)
		return ModelContainerHandle(
			container: try ModelContainer(for: schema, configurations: [configuration]))
	}
}

private final class HeldHandle {
	weak var handle: ModelContainerHandle?

	init(_ handle: ModelContainerHandle) {
		self.handle = handle
	}
}
