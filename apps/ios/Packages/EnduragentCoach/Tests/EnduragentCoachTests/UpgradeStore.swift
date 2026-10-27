import EnduragentCoachFixtures
import Foundation
import SwiftData
import Testing

@testable import EnduragentCoach

struct UpgradeStore {
	enum UnreadableRow: String, CaseIterable, CustomTestStringConvertible {
		case newerBodyVersion, malformedBody

		var testDescription: String { rawValue }
	}

	let root: URL
	let log: SwiftDataRecordLog

	init(_ scenario: String, folder: String, device: String) throws {
		let source = try #require(
			Bundle.module.url(forResource: scenario, withExtension: nil, subdirectory: folder))
		let root = try TestTemporaryFolders.make()
		try FileManager.default.copyItem(at: source, to: root)
		try self.init(reopening: root, device: device)
	}

	init(reopening root: URL, device: String) throws {
		self.root = root
		log = SwiftDataRecordLog(
			deviceId: DeviceID(rawValue: device),
			synced: try ModelContainerHandle.withoutCloudKit(
				storeURL: root.appending(path: "synced-records.store")),
			local: try ModelContainerHandle.withoutCloudKit(
				storeURL: root.appending(path: "local-records.store")))
	}

	func sync(_ record: AthleteRecord, as unreadable: UnreadableRow) throws {
		let handle = try ModelContainerHandle.withoutCloudKit(
			storeURL: root.appending(path: "synced-records.store"))
		let context = ModelContext(handle.container)
		let row = try StoredAthleteRecord(record: record)
		context.insert(row)
		switch unreadable {
		case .newerBodyVersion: row.bodyVersion = RecordCodec.currentBodyVersion + 1
		case .malformedBody: row.body = Data("{".utf8)
		}
		try context.save()
	}
}
