import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

extension SwiftDataSuites {
	@Suite(.timeLimit(.minutes(2))) struct AthleteOwnershipSnapshotTests {
		let phrasebook = CatalogPhrasebook(tag: .en)
		let athleteA = IntervalsAthleteID(rawValue: "i1001")
		let athleteB = IntervalsAthleteID(rawValue: "i2002")
		let savedLine = "Saved for another intervals.icu athlete (i1001)"

		@Test func savedOwnershipSurvivesRotationSwitchAndRelaunch() async throws {
			let phone = DeviceID(rawValue: "ownership-phone")
			let directory = try TestTemporaryFolders.make()
			let store = try makeSwiftDataLog(deviceId: phone, directory: directory)
			let fixture = try AthleteScopedCoachingFixture(store: store)
			guard case .intervals(let savedConnection, _) = fixture.accountA else {
				Issue.record("Fixture A has no saved connection")
				return
			}
			try await AthleteOwnershipFixture.seed(
				in: store, account: .intervals(connection: savedConnection, athlete: nil))
			let coach = await fixture.open()
			await coach.lifecycle(.becameActive)
			fixture.transport.respond = { _ in
				ScriptedReply([.text("Saved A reply."), .finish(reason: .stop)])
			}
			_ = try await coach.sendAndSettle("A's current conversation")
			let reset = try await beforeDeadline(within: .hangGuard) {
				await coach.resetAndSettle(in: .main)
			}
			#expect(try #require(reset) == .started(memory: .saved))
			let original = try await summary(on: coach, chat: AthleteOwnershipFixture.savedChat)
			#expect(original.attribution.ownership == .verified(try #require(athleteA)))
			#expect(line(original, connected: athleteB) == nil)
			try await fixture.connect(.rotatedA, using: coach)
			#expect(
				line(try await summary(on: coach, chat: original.id.chat), connected: athleteB)
					== nil)
			try fixture.peer.replace(.athleteB)
			await coach.lifecycle(.becameActive)
			let changed = try await summary(on: coach, chat: original.id.chat)
			#expect(line(changed, connected: athleteB) == savedLine)
			let changedHistory = try await coach.history()
			let savedOwner = AthleteOwnership.verified(try #require(athleteA))
			#expect(
				changedHistory.filter {
					$0.attribution.ownership == savedOwner
				}.count == 2)
			for conversation in changedHistory
			where conversation.firstQuestion != AthleteOwnershipFixture.unknownQuestion {
				#expect(line(conversation, connected: athleteB) == savedLine)
			}
			let archived = try #require(try await coach.archivedConversation(changed.id))
			#expect(archived.attribution == changed.attribution)
			#expect(archived.turns.map(\.athleteText) == [AthleteOwnershipFixture.savedQuestion])
			await coach.lifecycle(.willTerminate)
			let after = await fixture.open(
				store: try makeSwiftDataLog(deviceId: phone, directory: directory))
			await after.lifecycle(.becameActive)
			let reopened = try await summary(on: after, chat: original.id.chat)
			#expect(reopened.attribution == changed.attribution)
			#expect(line(reopened, connected: athleteB) == savedLine)
			#expect(
				try await after.archivedConversation(reopened.id)?.attribution
					== changed.attribution)
			try await fixture.connect(.athleteA, using: after)
			#expect(
				line(try await summary(on: after, chat: original.id.chat), connected: athleteA)
					== nil)
			await after.lifecycle(.willTerminate)
		}

		@Test func importedUnrecoverableAndMixedConversationsStayUnlabeled() async throws {
			let store = ImportingRecordLog()
			let fixture = try AthleteScopedCoachingFixture(store: store)
			let coach = await fixture.open()
			await coach.lifecycle(.becameActive)
			try fixture.peer.replace(.athleteB)
			await coach.lifecycle(.becameActive)
			try await AthleteOwnershipFixture.seed(in: store, account: fixture.accountA)
			let mixed: ChatID = "ownership-mixed"
			let recovered: ChatID = "ownership-original-claim"
			let unresolved: ChatID = "ownership-unbound"
			let mixedNote: ChatID = "ownership-mixed-review-note"
			let noteOnly: ChatID = "ownership-review-note-only"
			let accounts = [fixture.accountA, fixture.accountB, fixture.accountA]
			for (index, account) in accounts.enumerated() {
				let turn = TurnID(ulid: fixedUlid(20 + index))
				try await seed(
					store,
					[
						fixture.record(
							20 + index, account: account,
							body: .synced(
								sampleUser(chatId: mixed, text: "Mixed \(index)", turn: turn)))
					])
			}
			let turn = TurnID(ulid: fixedUlid(40))
			let attempt = AttemptID(ulid: fixedUlid(41))
			try await seed(
				store,
				[
					fixture.record(
						40, account: .unconnected,
						body: .synced(
							sampleUser(chatId: recovered, text: "Original A question", turn: turn))),
					fixture.record(
						41, account: fixture.accountA,
						body: .deviceLocal(
							.turnClaim(
								TurnClaimBody(
									chatId: recovered, turn: turn, attempt: attempt, process: nil,
									lease: .gracePeriodOnly))),
						cause: .operation(.turn(turn), attempt)),
					fixture.record(
						50, account: .unconnected,
						body: legacyUser(chatId: unresolved, text: "Unbound earlier question")),
					fixture.record(
						60, account: fixture.accountA,
						body: .synced(
							sampleUser(chatId: mixedNote, text: "A question with B's note"))),
					fixture.record(
						61, account: fixture.accountB,
						body: .synced(
							.reviewApplied(
								ReviewAppliedBody(chatId: mixedNote, summary: .deleteWorkout)))),
					fixture.record(
						70, account: fixture.accountA,
						body: .synced(
							.reviewApplied(
								ReviewAppliedBody(chatId: noteOnly, summary: .deleteWorkout)))),
				])
			store.notifyImport()
			for chat in [mixed, mixedNote, unresolved, AthleteOwnershipFixture.unknownChat] {
				let summary = try await summary(on: coach, chat: chat)
				#expect(summary.attribution.ownership == .unverified)
				#expect(line(summary, connected: athleteB) == nil)
				let archive = try #require(try await coach.archivedConversation(summary.id))
				#expect(archive.attribution == summary.attribution)
				#expect(!archive.turns.isEmpty)
			}
			let note = try await summary(on: coach, chat: noteOnly)
			#expect(line(note, connected: athleteB) == savedLine)
			let noteArchive = try #require(try await coach.archivedConversation(note.id))
			#expect(noteArchive.attribution == note.attribution)
			#expect(noteArchive.notes.count == 1)
			let original = try await summary(on: coach, chat: recovered)
			#expect(original.attribution.ownership == .verified(try #require(athleteA)))
			#expect(line(original, connected: athleteB) == savedLine)
			#expect(
				try await coach.archivedConversation(original.id)?.attribution
					== original.attribution)
			await coach.lifecycle(.willTerminate)
		}

		@Test func pendingReviewRetainsItsSavedAthlete() async throws {
			let fixture = try AthleteScopedCoachingFixture(store: InMemoryRecordLog())
			let coach = await fixture.open()
			fixture.transport.respond = ScriptedReply.sequence(
				[
					.toolCall(
						name: "intervals_create_workout",
						arguments:
							#"{"date":"1998-06-14","workout":{"name":"Endurance","steps":[{"type":"steady","duration":{"value":60,"unit":"minutes"},"power":{"kind":"percent_ftp","low":56,"high":75}}]}}"#
					),
					.finish(reason: .toolCalls), .text("Review ready."), .finish(reason: .stop),
				], otherwise: fixture.transport.respond)
			_ = try await coach.sendAndSettle("Prepare an endurance ride")
			let snapshots = await coach.observe(.main)
			let before = try #require(
				try await firstSnapshot(in: snapshots, within: .hangGuard) {
					$0.review != nil
				}?.review)
			#expect(before.attribution.ownership == .verified(try #require(athleteA)))
			#expect(await coach.decide(.presented(before.ref), in: .main) == .presentationRecorded)
			try fixture.peer.replace(.athleteB)
			await coach.lifecycle(.becameActive)
			let blocked = try #require(
				try await firstSnapshot(in: snapshots, within: .hangGuard) {
					$0.review?.notice?.kind == .accountChanged
				}?.review)
			#expect(blocked.attribution.ownership == before.attribution.ownership)
			#expect(blocked.controls == .none)
			#expect(blocked.notice?.key == Catalog.reviewAccountChanged)
			#expect(blocked.cards == before.cards)
			await coach.lifecycle(.willTerminate)
			let after = await fixture.open()
			await after.lifecycle(.becameActive)
			let reopened = try #require(
				try await firstSnapshot(in: await after.observe(.main), within: .hangGuard) {
					$0.review?.notice?.kind == .accountChanged
				}?.review)
			#expect(reopened.attribution == blocked.attribution)
			#expect(reopened.controls == .none)
			#expect(fixture.peer.athleteA.events.isEmpty && fixture.peer.athleteB.events.isEmpty)
			await after.lifecycle(.willTerminate)
		}

		private func summary(on coach: Coach, chat: ChatID) async throws
			-> ArchivedConversationSummary
		{
			try #require(try await coach.history().first { $0.id.chat == chat })
		}

		private func line(_ summary: ArchivedConversationSummary, connected: IntervalsAthleteID?)
			-> String?
		{
			summary.attribution.historyLine(in: phrasebook, connectedAthlete: connected)
		}
	}
}
