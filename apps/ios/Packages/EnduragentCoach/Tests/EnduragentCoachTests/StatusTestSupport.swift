import EnduragentCoachFixtures
import Testing

@testable import EnduragentCoach

extension Coach {
	func observedStatus() async throws -> CoachStatus {
		return try #require(try await observeStatus().status { _ in true })
	}

	func refreshedStatus() async throws -> CoachStatus {
		await lifecycle(.becameActive)
		return try await observedStatus()
	}
}

extension AsyncStream where Element == CoachStatus {
	func status(matching matches: @escaping @Sendable (CoachStatus) -> Bool) async throws
		-> CoachStatus?
	{
		try await beforeDeadline(within: .hangGuard) {
			await first(where: matches)
		} ?? nil
	}
}
