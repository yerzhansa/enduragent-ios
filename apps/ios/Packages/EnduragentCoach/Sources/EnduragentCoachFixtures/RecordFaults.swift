import EnduragentCoach
import Foundation

public final class RecordFaults: Sendable {
	package let log: FaultInjectingRecordLog
	package let released: FixtureStoreRelease

	package init(directory: URL, deviceId: DeviceID) throws {
		let release = FixtureStoreRelease()
		released = release
		log = try autoreleasepool {
			FaultInjectingRecordLog(
				wrapping: SwiftDataRecordLog(
					deviceId: deviceId,
					synced: try ModelContainerHandle.withoutCloudKit(
						storeURL: directory.appending(
							path: ModelContainerHandle.syncedStoreFileName)),
					local: try ModelContainerHandle.withoutCloudKit(
						storeURL: directory.appending(path: ModelContainerHandle.localStoreFileName)
					)),
				release: release)
		}
	}

	public var failNextAppend: Bool {
		get { log.failNextAppend }
		set { log.failNextAppend = newValue }
	}

	public var failFetches: Bool {
		get { log.failFetches }
		set { log.failFetches = newValue }
	}

	public var failRecoveryReads: Bool {
		get { log.failRecoveryReads }
		set { log.failRecoveryReads = newValue }
	}

	public var failSyncedAppends: Bool {
		get { log.failSyncedAppends }
		set { log.failSyncedAppends = newValue }
	}

	public func failAppends(ofKind kind: String) throws {
		try log.failAppends(ofKind: kind)
	}

	#if DEBUG
		public func failNextReviewRead() {
			log.failNextFetch(in: .synced([.reviewWrite]))
		}
	#endif
}
