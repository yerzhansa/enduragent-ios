import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

extension SwiftDataSuites {
	@Suite struct CoachUpgradeTests {
		static let askAgain =
			"This review was prepared before the app was updated. Ask the coach again."

		@Test func anOpenReviewOpensOfflineAsAskTheCoachAgainWithNoControlAndStaysSoOnline()
			async throws
		{
			let seed = try await M2Seed(
				try UpgradeStore("open-review", folder: M2Seed.folder, device: M2Seed.device).log)
			seed.calendar.failReads()
			let coach = try await seed.coach()

			await coach.lifecycle(.becameActive)

			let offline = try #require(
				try await firstSnapshot(in: await coach.observe(.main), within: .hangGuard) {
					sentences($0).contains(Self.askAgain)
				})
			#expect(offline.review == nil)
			#expect(sentences(offline).filter { $0 == Self.askAgain }.count == 1)

			seed.calendar.restoreReads()
			await coach.lifecycle(.becameActive)

			let online = try #require(await coach.currentSnapshot(.main))
			#expect(online.review == nil)
			#expect(sentences(online) == sentences(offline))
			#expect(seed.calendar.calls.isEmpty)
		}

		@Test func anUnknownWriteOpensOfflineAsAnUnconfirmedChangeAndSettlesOnline()
			async throws
		{
			let seed = try await M2Seed(
				try UpgradeStore("unknown-write", folder: M2Seed.folder, device: M2Seed.device)
					.log)
			seed.calendar.failReads()
			let coach = try await seed.coach()

			await coach.lifecycle(.becameActive)

			let opened = try #require(
				try await firstSnapshot(in: await coach.observe(.main), within: .hangGuard) {
					$0.review != nil
				})
			let shown = try #require(opened.review)
			#expect(shown.controls == .none)
			#expect(
				await coach.decide(.presented(shown.ref), in: .main) == .presentationRecorded)
			let presented = try #require(await coach.currentSnapshot(.main))
			let armed = try #require(presented.review)
			guard case .armed(.checkAgainOrCancel, _) = armed.controls else {
				Issue.record("the unconfirmed change did not offer Check again and Cancel")
				return
			}
			#expect(armed.content.cards.map(\.date) == ["1998-06-16"])

			seed.landTheUnknownAdd()
			seed.calendar.restoreReads()
			await coach.lifecycle(.becameActive)

			let settled = try await firstSnapshot(
				in: await coach.observe(.main), within: .hangGuard
			) { $0.review == nil }
			#expect(settled != nil)
			#expect(try await seed.chain().last?.stage == .completed)
			#expect(seed.calendar.writes.isEmpty)
		}

		@Test func theCompletedScenarioKeepsItsNotesAfterTheUpgradeWithNoControl() async throws {
			let seed = try await M2Seed(
				try UpgradeStore("completed", folder: M2Seed.folder, device: M2Seed.device).log)
			let coach = try await seed.coach()
			let before = try #require(await coach.currentSnapshot(.main))

			await coach.lifecycle(.becameActive)

			let after = try #require(await coach.currentSnapshot(.main))
			#expect(sentences(before).count == 2)
			#expect(sentences(after) == sentences(before))
			#expect(before.review == nil)
			#expect(after.review == nil)
			#expect(seed.calendar.calls.isEmpty)
		}

		@Test(arguments: StoredCount.allCases)
		func anOldTurnWithStoredCalendarWriteCountsKeepsItsNotice(_ stored: StoredCount)
			async throws
		{
			let store = InMemoryRecordLog()
			let turn = TurnID(ulid: fixedUlid(60))
			try await seed(
				store,
				[
					storedRecord(
						device: store.deviceId, wall: 1,
						body: .synced(sampleUser(chatId: .main, text: "Add a ride", turn: turn))),
					storedRecord(
						device: store.deviceId, wall: 2,
						body: .synced(
							.turnSettled(
								TurnSettledBody(
									chatId: .main, turn: turn,
									attempt: AttemptID(ulid: fixedUlid(61)),
									settlement: stored.settlement)))),
				])
			let coach = await makeCoach(transport: FakeModelTransport(), store: store)

			let state = try #require(await coach.settledState(of: turn, in: .main))

			#expect(turnNotice(of: state)?.key == stored.notice)
		}

		enum StoredCount: String, CaseIterable, CustomTestStringConvertible {
			case interruptedUnverified, interruptedVerified, savedUnverified

			var testDescription: String { rawValue }

			var settlement: Settlement {
				switch self {
				case .interruptedUnverified:
					.interrupted(partial: "", cause: .processEnded, saved: written(unverified: 1))
				case .interruptedVerified:
					.interrupted(partial: "", cause: .processEnded, saved: written(unverified: 0))
				case .savedUnverified:
					.savedWork(.savedUnverified, saved: written(unverified: 1))
				}
			}

			var notice: CatalogKey {
				switch self {
				case .interruptedUnverified, .savedUnverified: Catalog.chatNoticeCalendarUnverified
				case .interruptedVerified: Catalog.chatTurnInterruptedSomeSaved
				}
			}

			private func written(unverified: Int) -> WriteSummary {
				WriteSummary(
					memorySections: 0, ledgerEvents: 0, planConfirmations: 0, calendarWrites: 1,
					unverifiedCalendarWrites: unverified)
			}
		}

		private func sentences(_ snapshot: ChatSnapshot) -> [String] {
			ReviewOutcomeNotesTests.sentences(snapshot.notes.values.flatMap { $0 }).sorted()
		}
	}
}
