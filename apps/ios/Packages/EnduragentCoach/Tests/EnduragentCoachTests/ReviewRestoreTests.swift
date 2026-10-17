import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

extension SwiftDataSuites {
	@Suite(.timeLimit(.minutes(1))) struct ReviewRestoreTests {
		enum Return: String, CaseIterable, CustomTestStringConvertible {
			case relaunch, deviceRestart

			var testDescription: String { rawValue }
		}

		let phone = DeviceID(rawValue: "review-restore-phone")

		@Test(arguments: Return.allCases)
		func aReviewPreparedMoreThanTenMinutesAgoIsRestoredWithItsControls(_ way: Return)
			async throws
		{
			let directory = try TestTemporaryFolders.make()
			let turns = ReviewTurns()
			let before = await turns.coach(
				over: try makeSwiftDataLog(deviceId: phone, directory: directory))
			let prepared = try await turns.committed(ReviewTurns.fourChanges, on: before)
			let shown = try #require(try await before.desk.snapshot(chat: .main))
			#expect(await before.desk.decide(.presented(shown.ref)) == .presentationRecorded)
			guard
				case .armed(let set, _) = try #require(try await before.desk.snapshot(chat: .main))
					.controls
			else {
				Issue.record("the prepared review never armed its controls")
				return
			}
			let requests = turns.transport.requests.count
			let preparedAt = turns.clock.now
			let elevenMinutes: TimeInterval = 11 * 60
			let clock: FixedClock
			switch way {
			case .relaunch:
				await before.lifecycle(.willTerminate)
				turns.clock.advance(by: elevenMinutes)
				clock = turns.clock
			case .deviceRestart:
				clock = FixedClock(now: "1998-09-08T00:41:00+12:00", timeZone: "Pacific/Auckland")
			}
			#expect(clock.now.timeIntervalSince(preparedAt) > 10 * 60)
			let transport = FakeModelTransport()
			let after = await makeCoach(
				transport: transport, intervals: turns.intervals,
				store: try makeSwiftDataLog(deviceId: phone, directory: directory), clock: clock,
				tools: .workoutReview)

			await after.lifecycle(.becameActive)
			await after.desk.recover()

			#expect(try await turns.head(of: after).1 == prepared)
			let restored = try #require(try await after.desk.snapshot(chat: .main))
			#expect(restored.ref.review == prepared.id)
			#expect(restored.ref.revision == prepared.revision)
			#expect(restored.cards == shown.cards)
			#expect(restored.controls == .none)
			#expect(await after.desk.decide(.presented(restored.ref)) == .presentationRecorded)
			guard
				case .armed(set, let token) = try #require(
					try await after.desk.snapshot(chat: .main)
				).controls
			else {
				Issue.record("the restored review did not arm the same control set")
				return
			}
			#expect(token.ref == restored.ref)
			#expect(transport.requests.isEmpty)
			#expect(turns.transport.requests.count == requests)
		}
	}
}
