import EnduragentCoach
import Foundation

public struct FixtureRecordStore: Sendable {
	public let store: RecordStore
	public let faults: RecordFaults

	public init(directory: URL, deviceId: DeviceID, unreadable: Bool = false) throws {
		if unreadable {
			try FileManager.default.createDirectory(
				at: directory.appending(path: ModelContainerHandle.syncedStoreFileName),
				withIntermediateDirectories: true)
		}
		self.faults = try RecordFaults(directory: directory, deviceId: deviceId)
		self.store = RecordStore(log: faults.log)
	}
}
