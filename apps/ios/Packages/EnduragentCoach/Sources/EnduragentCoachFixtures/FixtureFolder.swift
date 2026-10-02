import Foundation
import Synchronization

public final class FixtureFolder: Sendable {
	@TaskLocal public static var current: FixtureFolder?

	public let directory: URL
	public let waitingForStores: AsyncStream<Void>
	private let waiting: AsyncStream<Void>.Continuation
	private let stores = Mutex<[FixtureStoreRelease]>([])

	public init(directory: URL) throws {
		self.directory = directory
		(waitingForStores, waiting) = AsyncStream.makeStream()
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
	}

	package func track(_ release: FixtureStoreRelease, in directory: URL) {
		precondition(self.directory == directory, "The store must belong to the fixture folder")
		stores.withLock { $0.append(release) }
	}

	public func cleanup(releasing owners: @Sendable () async throws -> Void) async throws {
		try await owners()
		try await waitUntilUnused()
		try FileManager.default.removeItem(at: directory)
	}

	public func waitUntilUnused() async throws {
		let deadline = ContinuousClock.now + .seconds(5)
		for store in stores.withLock({ $0 }) {
			waiting.yield()
			try await store.wait(until: deadline)
		}
	}
}

package final class FixtureStoreRelease: Sendable {
	private let released = Mutex(false)

	package func wait(until deadline: ContinuousClock.Instant) async throws {
		while !released.withLock({ $0 }) {
			guard ContinuousClock.now < deadline else {
				throw FixtureCleanupFailure.storeOwnerNotReleased
			}
			try await Task.sleep(for: .milliseconds(10))
		}
	}

	package func finish() {
		released.withLock { $0 = true }
	}
}

public enum FixtureCleanupFailure: Error, CustomStringConvertible {
	case storeOwnerNotReleased

	public var description: String {
		"A fixture store owner was not released within five seconds"
	}
}
