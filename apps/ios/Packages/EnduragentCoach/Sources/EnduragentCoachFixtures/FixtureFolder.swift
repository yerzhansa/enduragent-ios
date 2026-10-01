import Foundation
import Synchronization

public final class FixtureFolder: Sendable {
	@TaskLocal public static var current: FixtureFolder?

	public let directory: URL
	private let stores = Mutex<[FixtureStoreRelease]>([])

	public init(directory: URL) throws {
		self.directory = directory
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
	}

	package func track(_ release: FixtureStoreRelease, in directory: URL) {
		precondition(self.directory == directory, "The store must belong to the fixture folder")
		stores.withLock { $0.append(release) }
	}

	public func cleanup(releasing owners: @Sendable () async throws -> Void) async throws {
		try FileManager.default.removeItem(at: directory)
		try await owners()
		for store in stores.withLock({ $0 }) {
			await store.wait()
		}
	}
}

package final class FixtureStoreRelease: Sendable {
	private let waiters = Mutex<[CheckedContinuation<Void, Never>]?>([])
	package let waiting: AsyncStream<Void>
	private let entered: AsyncStream<Void>.Continuation

	package init() {
		(waiting, entered) = AsyncStream.makeStream()
	}

	package func wait() async {
		await withCheckedContinuation { continuation in
			let released = waiters.withLock { waiters in
				guard waiters != nil else { return true }
				waiters?.append(continuation)
				return false
			}
			entered.yield()
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
		entered.finish()
	}
}
