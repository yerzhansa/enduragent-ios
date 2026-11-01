import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

extension SwiftDataSuites {
	@Suite struct UpgradeStoreFromM5Tests {
		static let folder = "Fixtures/build-0f943324"
		static let device = "build-0f943324"
		static let nineMinutesAfterTheSeedSettled = FixedClock(
			now: "1998-06-13T08:09:00+02:00", timeZone: "Europe/Amsterdam")

		@Test func waitingConfirmationKeepsItsExpiry() async throws {
			let store = try UpgradeStore("filled", folder: Self.folder, device: Self.device)
			let turns = PlanTurns(clock: HeldClock(calendar: Self.nineMinutesAfterTheSeedSettled))
			let coach = await turns.coach(over: store.log)

			let shown = try #require(await coach.currentSnapshot(.main))
			#expect(shown.turns.count == 4)
			#expect(shown.review?.cards.count == 1)
			#expect(shown.plans.map(\.summary.name) == ["Threshold Block", "Base Build"])
			#expect(shown.plans.last?.summary.replaces == "Threshold Block")
			#expect(shown.plans.map(\.state) == [.saved, .waiting(.unarmed)])
			#expect(
				try await memory(in: store.log) == [
					"_updated: 1998-06-13\nRides with a group on Saturdays."
				])
			#expect(try await receipts(in: store.log) == [EventID(rawValue: 1)])
			#expect(await coach.languagePreference() == .fixed(.fr))

			try await turns.clock.waitUntilHeld(.seconds(60))
			turns.clock.advance(by: .seconds(60))

			let expired = try await turns.waitForCards(on: coach) {
				$0.map(\.state) == [.saved, .expired]
			}
			#expect(expired != nil)
			#expect(try await coach.currentSnapshot(.main)?.review?.cards.count == 1)
		}

		private func memory(in log: SwiftDataRecordLog) async throws -> [String] {
			try await log.fetch(RecordQuery(scope: .synced([.memorySection]))).records
				.compactMap { record in
					guard case .synced(.memorySection(let body)) = record.body else { return nil }
					return body.content
				}
		}

		private func receipts(in log: SwiftDataRecordLog) async throws -> [EventID] {
			let reviews = try await log.fetch(RecordQuery(scope: .deviceLocal([.workoutReview])))
				.records.compactMap { record -> WorkoutReview? in
					guard case .deviceLocal(.workoutReview(let body)) = record.body else {
						return nil
					}
					return body.review
				}
			var events: [EventID] = []
			for review in reviews {
				for finished in review.work.finished {
					guard case .saved(let receipt) = finished.result,
						!events.contains(receipt.event)
					else { continue }
					events.append(receipt.event)
				}
			}
			return events
		}
	}
}
