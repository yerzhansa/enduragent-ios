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
		await waitUntilUnused()
		try FileManager.default.removeItem(at: directory)
	}

	public func waitUntilUnused() async {
		for store in stores.withLock({ $0 }) {
			waiting.yield()
			await store.wait()
		}
	}
}

package final class FixtureStoreRelease: Sendable {
	private let waiters = Mutex<[CheckedContinuation<Void, Never>]?>([])

	package func wait() async {
		await withCheckedContinuation { continuation in
			let released = waiters.withLock { waiters in
				guard waiters != nil else { return true }
				waiters?.append(continuation)
				return false
			}
			if released { continuation.resume() }
		}
	}

	package func finish() {
		let pending = waiters.withLock { waiters in
			let pending = waiters ?? []
			waiters = nil
			return pending
		}
		for waiter in pending { waiter.resume() }
	}
}
