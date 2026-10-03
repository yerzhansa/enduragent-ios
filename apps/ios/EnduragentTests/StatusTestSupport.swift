import EnduragentCoach
import EnduragentCoachFixtures
import Testing

@testable import Enduragent

extension Coach {
	func observedStatus() async throws -> CoachStatus {
		var snapshots = await observeStatus().makeAsyncIterator()
		return try #require(await snapshots.next())
	}
}

extension FakeIntervalsReadGate {
	func waitForRead() async throws {
		try await withThrowingTaskGroup(of: Bool.self) { group in
			defer { group.cancelAll() }
			group.addTask {
				await self.waitUntilEntered()
				try Task.checkCancellation()
				return true
			}
			group.addTask {
				try await Task.sleep(for: TestWaitLimit.hangGuard.duration)
				return false
			}
			try #require(try await group.next() == true)
		}
	}
}

@MainActor
extension ShellModel {
	func waitForStatus(_ matches: (CoachStatus) -> Bool) async throws {
		let deadline = ContinuousClock.now + TestWaitLimit.hangGuard.duration
		while matches(status) != true, ContinuousClock.now < deadline {
			try await Task.sleep(for: .milliseconds(10))
		}
		try #require(matches(status) == true)
	}
}
