import Foundation
import SwiftData

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
		try make(
			name: "local-records",
			storeURL: directory.appending(path: localStoreFileName),
			cloudKitDatabase: .none
		)
	}

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
