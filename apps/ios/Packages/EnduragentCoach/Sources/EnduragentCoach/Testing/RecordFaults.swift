import Foundation

public final class RecordFaults: Sendable {
	package let log: FaultInjectingRecordLog

	public init(directory: URL, deviceId: DeviceID) throws {
		log = FaultInjectingRecordLog(
			wrapping: SwiftDataRecordLog(
				deviceId: deviceId,
				synced: try ModelContainerHandle.withoutCloudKit(
					storeURL: directory.appending(path: ModelContainerHandle.syncedStoreFileName)),
				local: try ModelContainerHandle.withoutCloudKit(
					storeURL: directory.appending(path: ModelContainerHandle.localStoreFileName))))
	}

	public var failNextAppend: Bool {
		get { log.failNextAppend }
		set { log.failNextAppend = newValue }
	}

	public var failRecoveryReads: Bool {
		get { log.failRecoveryReads }
		set { log.failRecoveryReads = newValue }
	}

	public func failAppends(ofKind kind: String) {
		log.failAppends(ofKind: kind)
	}
}
