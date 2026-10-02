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

@MainActor
extension ShellModel {
	func waitForStatus(_ matches: (CoachStatus) -> Bool) async throws {
		let deadline = ContinuousClock.now + TestWaitLimit.hangGuard.duration
		while status.map(matches) != true, ContinuousClock.now < deadline {
			try await Task.sleep(for: .milliseconds(10))
		}
		try #require(status.map(matches) == true)
	}
}
