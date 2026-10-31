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
					local: try ModelContainerHandle.deviceLocal(directory: directory)),
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

	package var failErasures: Set<RecordLocality> {
		get { log.failErasures }
		set { log.failErasures = newValue }
	}

	public var export: FixtureExport {
		get { log.export }
		set { log.export = newValue }
	}

	public var failSyncedAppends: Bool {
		get { log.failSyncedAppends }
		set { log.failSyncedAppends = newValue }
	}

	public func failAppends(ofKind kind: String) throws {
		try log.failAppends(ofKind: kind)
	}

	public func holdAppends(ofKind kind: String) throws {
		try log.holdAppends(ofKind: kind)
	}

	#if DEBUG
		public func failNextReviewRead() {
			log.failNextFetch(in: .deviceLocal([.workoutReview]))
		}

		public func failReviewAppend(after appends: Int) throws {
			try log.failAppend(ofKind: DeviceLocalKind.workoutReview.rawValue, skipping: appends)
		}
	#endif
}
