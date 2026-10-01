import Testing

@testable import EnduragentCoach

extension Coach {
	func observedStatus() async throws -> CoachStatus {
		var snapshots = await observeStatus().makeAsyncIterator()
		return try #require(await snapshots.next())
	}

	func refreshedStatus() async throws -> CoachStatus {
		await lifecycle(.becameActive)
		return try await observedStatus()
	}
}

extension AsyncStream where Element == CoachStatus {
	func status(matching matches: @escaping @Sendable (CoachStatus) -> Bool) async -> CoachStatus? {
		await withTaskGroup(of: CoachStatus?.self) { group in
			group.addTask { await first(where: matches) }
			group.addTask {
				do {
					try await Task.sleep(for: .seconds(2))
				} catch is CancellationError {
					return nil
				} catch {
					Issue.record(error)
				}
				return nil
			}
			let result = await group.next()
			group.cancelAll()
			return result ?? nil
		}
	}
}
