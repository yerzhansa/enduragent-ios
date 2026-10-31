import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

extension SwiftDataSuites {
	@Suite struct CoachLifecycleRecoveryTests {
		@Test func eachBecameActiveReadsTheUnconfirmedChangeAgainUntilItIsFound() async throws {
			let seed = try await M2Seed(
				try UpgradeStore("unknown-write", folder: M2Seed.folder, device: M2Seed.device)
					.log)
			seed.calendar.failReads()
			let coach = try await seed.coach()

			await coach.lifecycle(.becameActive)

			#expect(seed.calendarReads() == 1)
			guard case .waiting(.unconfirmed) = try #require(try await seed.chain().last).stage
			else {
				Issue.record("the offline read did not leave the change unconfirmed")
				return
			}

			seed.landTheUnknownAdd()
			seed.calendar.restoreReads()
			await coach.lifecycle(.becameActive)

			#expect(seed.calendarReads() == 2)
			#expect(try await seed.chain().last?.stage == .completed)
			#expect(
				try await seed.outcomes().flatMap(\.lines).map(\.result) == [.seenOnCalendar])
			#expect(seed.calendar.writes.isEmpty)
			let settled = try await firstSnapshot(
				in: await coach.observe(.main), within: .hangGuard
			) { $0.review == nil }
			#expect(settled != nil)
		}
	}
}
