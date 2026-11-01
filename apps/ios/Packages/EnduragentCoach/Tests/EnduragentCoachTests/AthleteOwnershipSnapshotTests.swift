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
			let peer = DeviceID(rawValue: "ownership-importing-peer")
			let replies: [(ChatID, TrainingAccount, TrainingAccount, Bool)] = [
				("ownership-mixed-reply", fixture.accountA, fixture.accountB, false),
				("ownership-unknown-reply", fixture.accountB, .unconnected, false),
				("ownership-mixed-legacy-reply", fixture.accountA, fixture.accountB, true),
				("ownership-unknown-legacy-reply", fixture.accountB, .unconnected, true),
			]
			for (offset, entry) in replies.enumerated() {
				let (chat, questionAccount, replyAccount, legacy) = entry
				let index = 80 + offset * 10
				let turn = TurnID(ulid: fixedUlid(index))
				try await seed(
					store,
					[
						fixture.record(
							index, account: questionAccount,
							body: legacy
								? legacyUser(chatId: chat, text: "Imported question")
								: .synced(
									sampleUser(chatId: chat, text: "Imported question", turn: turn)),
							device: peer),
						fixture.record(
							index + 1, account: replyAccount,
							body: legacy
								? legacyReply(chatId: chat, text: "Imported reply")
								: .synced(
									sampleReply(chatId: chat, turn: turn, text: "Imported reply")),
							device: peer),
					])
			}
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
						42, account: .unconnected,
						body: .synced(
							.turnSettled(
								TurnSettledBody(
									chatId: recovered, turn: turn, attempt: attempt,
									settlement: .replied(.model("Original A reply"), lineage: nil)))
						)),
					fixture.record(
						50, account: .unconnected,
						body: legacyUser(chatId: unresolved, text: "Unbound earlier question")),
					fixture.record(
						60, account: fixture.accountA,
						body: .synced(
							sampleUser(chatId: mixedNote, text: "A question with B's note"))),
					fixture.record(
						61, account: fixture.accountB,
						body: .legacy(
							.reviewApplied(
								ReviewAppliedBody(chatId: mixedNote, summary: .deleteWorkout)))),
					fixture.record(
						70, account: fixture.accountA,
						body: .legacy(
							.reviewApplied(
								ReviewAppliedBody(chatId: noteOnly, summary: .deleteWorkout)))),
				])
			store.notifyImport()
			for chat in [mixed, mixedNote, unresolved, AthleteOwnershipFixture.unknownChat]
				+ replies.map({ $0.0 })
			{
				let summary = try await summary(on: coach, chat: chat)
				#expect(summary.attribution.ownership == .unverified)
				#expect(line(summary, connected: athleteB) == nil)
				let archive = try #require(try await coach.archivedConversation(summary.id))
				#expect(archive.attribution == summary.attribution)
				#expect(!archive.turns.isEmpty)
				if replies.contains(where: { $0.0 == chat }) {
					#expect(archive.turns.compactMap { replyText($0.state) } == ["Imported reply"])
				}
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

		@Test func importedM1SettlementOwnershipMatchesHistoryAndArchive() async throws {
			let store = ImportingRecordLog()
			let fixture = try AthleteScopedCoachingFixture(store: store)
			let coach = await fixture.open()
			await coach.lifecycle(.becameActive)
			try fixture.peer.replace(.athleteB)
			await coach.lifecycle(.becameActive)
			let chat: ChatID = "ownership-m1-settlement"
			let peer = DeviceID(rawValue: "ownership-m1-peer")
			let turn = TurnID(ulid: fixedUlid(120))
			try await seed(
				store,
				[
					fixture.record(
						120, account: .unconnected,
						body: .synced(
							sampleUser(chatId: chat, text: "Imported M1 question", turn: turn)),
						device: peer),
					fixture.record(
						121, account: fixture.accountA,
						body: .synced(
							sampleReply(chatId: chat, turn: turn, text: "Saved M1 reply")),
						device: peer),
				])
			store.notifyImport()
			let imported = try await summary(on: coach, chat: chat)
			#expect(imported.attribution.ownership == .verified(try #require(athleteA)))
			#expect(line(imported, connected: athleteB) == savedLine)
			let archive = try #require(try await coach.archivedConversation(imported.id))
			#expect(archive.attribution == imported.attribution)
			#expect(archive.turns.map(\.athleteText) == ["Imported M1 question"])
			#expect(archive.turns.compactMap { replyText($0.state) } == ["Saved M1 reply"])
			await coach.lifecycle(.willTerminate)
		}

		@Test func theFirstAthletesSavedPlanStaysAwayFromTheSecondAfterAReconnect() async throws {
			let fixture = try AthleteScopedCoachingFixture(store: InMemoryRecordLog())
			let plan: JSONValue = .object(["name": .string("A_PLAN"), "totalWeeks": .number(10)])
			try await seed(
				fixture.store,
				[
					storedRecord(
						device: fixture.store.deviceId, wall: 10, ulid: fixedUlid(10),
						account: fixture.accountA, body: try SavedPlanRows.body(plan))
				])
			let coach = await fixture.open()

			let forA = try await readPlans(fixture, coach)
			try await fixture.connect(.athleteB, using: coach)
			let forB = try await readPlans(fixture, coach)

			#expect(
				try MemoryProbe.systemText(in: forA).contains(
					"## Current Plan\n- Name: A_PLAN\n- Duration: 10 weeks"))
			#expect(try fixture.toolText("memory_query", in: forA).contains("A_PLAN"))
			#expect(try planLoad(in: forA) == plan)
			fixture.assertAbsent("A_PLAN", from: forB)
			#expect(
				try MemoryProbe.systemText(in: forB).contains("## Current Plan\nNo plan saved yet.")
			)
			#expect(try planLoad(in: forB) == .object(["message": .string("No plan saved yet.")]))
			let memory = Memory(
				ledger: Ledger(
					log: fixture.store, clock: fixture.clock,
					diagnostics: DiagnosticsLog(clock: fixture.clock)),
				clock: fixture.clock)
			#expect(
				try await memory.loadSnapshot(for: fixture.accountA).savedPlans.newest?.value
					== plan)
			#expect(try await memory.loadSnapshot(for: fixture.accountB).savedPlans.newest == nil)
			#expect(
				try await memory.loadSnapshot(for: testStamp(account: fixture.accountA)).savedPlans
					.newest?.value == plan)
			#expect(
				try await memory.loadSnapshot(for: testStamp(account: fixture.accountB)).savedPlans
					.newest == nil)
			await coach.lifecycle(.willTerminate)
		}

		private func readPlans(_ fixture: AthleteScopedCoachingFixture, _ coach: Coach)
			async throws -> CompletionRequest
		{
			try await MemoryProbe.turn(
				[
					.toolCall(name: "plan_load", arguments: "{}"),
					.toolCall(
						name: "memory_query", arguments: #"{"from":"1998-06-13","to":"1998-06-13"}"#
					),
				], saying: "What is my current plan?", expecting: "Here is your plan.",
				using: coach, transport: fixture.transport)
		}

		private func planLoad(in request: CompletionRequest) throws -> JSONValue {
			let call = try #require(
				request.messages.flatMap(\.toolCalls).first { $0.name == "plan_load" })
			return try MemoryProbe.data(
				in: try #require(
					request.messages.first { $0.role == .tool && $0.toolCallId == call.id }))
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
