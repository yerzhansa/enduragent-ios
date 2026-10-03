import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

extension SwiftDataSuites {
	@Suite(.timeLimit(.minutes(2))) struct AthleteScopedCoachingTests {
		@Test(arguments: [false, true])
		func localAndSyncedReconnectReadOnlySelectedAthlete(synced: Bool) async throws {
			let fixture = try AthleteScopedCoachingFixture(store: InMemoryRecordLog())
			try await fixture.seedInformation("A_ONLY", account: fixture.accountA, offset: 0)
			try await fixture.seedInformation("B_ONLY", account: fixture.accountB, offset: 20)
			let orphan = fixture.record(
				50, account: fixture.accountA,
				body: .synced(
					.memorySection(
						MemorySectionBody(
							name: SectionName(rawValue: "A_ONLY_ORPHAN"),
							content: "A_ONLY_PRIVATE"))))
			try await seed(fixture.store, [orphan])
			let coach = await fixture.open()
			try fixture.assertInformation(
				"A_ONLY", excluding: "B_ONLY",
				in: await fixture.read(using: coach, question: "A_ONLY_LIVE_QUESTION"))
			if synced {
				try fixture.peer.replace(.athleteB)
				await coach.lifecycle(.becameActive)
			} else {
				try await fixture.connect(.athleteB, using: coach)
			}
			try fixture.assertInformation(
				"B_ONLY", excluding: "A_ONLY", in: await fixture.read(using: coach))
			await coach.lifecycle(.willTerminate)
		}

		@Test func rotationReopenAndImportKeepOriginalAccounts() async throws {
			let phone = DeviceID(rawValue: "scoped-rotation-phone")
			let directory = try TestTemporaryFolders.make()
			let store = try makeSwiftDataLog(deviceId: phone, directory: directory)
			let fixture = try AthleteScopedCoachingFixture(store: store)
			let original = try await fixture.seedInformation(
				"A_ONLY", account: fixture.accountA, offset: 0)
			try await fixture.seedInformation("B_ONLY", account: fixture.accountB, offset: 20)
			let before = await fixture.open()
			try fixture.assertInformation(
				"A_ONLY", excluding: "B_ONLY",
				in: await fixture.read(using: before, question: "A_ONLY_LIVE_QUESTION"))
			try await fixture.connect(.rotatedA, using: before)
			await before.lifecycle(.willTerminate)
			let reopened = ImportingRecordLog(
				inner: try makeSwiftDataLog(deviceId: phone, directory: directory))
			let after = await fixture.open(store: reopened)
			await after.lifecycle(.becameActive)
			let peer = DeviceID(rawValue: "scoped-import-phone")
			let observation = fixture.record(
				60, account: fixture.accountA,
				body: .synced(.trainingIdentityObserved), device: peer)
			guard case .intervals(let originalConnection, _) = fixture.accountA else {
				Issue.record("Fixture A has no connection")
				return
			}
			let imported = fixture.record(
				61, account: .intervals(connection: originalConnection, athlete: nil),
				body: .synced(.dailyNote(DailyNoteBody(note: "A_ONLY_IMPORTED"))), device: peer)
			let peerTurn = TurnID(ulid: fixedUlid(62))
			let question = fixture.record(
				62, account: fixture.accountA,
				body: .synced(
					sampleUser(chatId: .main, text: "A_ONLY_IMPORTED_QUESTION", turn: peerTurn)),
				device: peer)
			let reply = fixture.record(
				63, account: fixture.accountA,
				body: .synced(
					sampleReply(chatId: .main, turn: peerTurn, text: "A_ONLY_IMPORTED_REPLY")),
				device: peer)
			try await seed(reopened, [observation, imported, question, reply])
			reopened.notifyImport()
			try #require(
				try await firstSnapshot(in: await after.observe(.main), within: .hangGuard) {
					$0.turns.contains { $0.athleteText == "A_ONLY_IMPORTED_QUESTION" }
				} != nil)
			let request = try await fixture.read(using: after)
			try fixture.assertInformation("A_ONLY", excluding: "B_ONLY", in: request)
			#expect(request.messages.contains { $0.content.contains("A_ONLY_IMPORTED_QUESTION") })
			#expect(request.messages.contains { $0.content.contains("A_ONLY_LIVE_QUESTION") })
			#expect(try fixture.toolText("memory_query", in: request).contains("A_ONLY_IMPORTED"))
			let saved = try await reopened.fetch(RecordQuery(scope: .everySynced)).records
			for record in original + [observation, imported, question, reply] {
				#expect(saved.first { $0.ulid == record.ulid } == record)
			}
			#expect(original.allSatisfy { $0.account == fixture.accountA })
			#expect(try fixture.secrets.intervalsConnection()?.account != fixture.accountA)
			await after.lifecycle(.willTerminate)
		}

		@Test func unconnectedAndM1MemoryBindFirstAthleteDurably() async throws {
			let phone = DeviceID(rawValue: "scoped-unconnected-phone")
			let directory = try TestTemporaryFolders.make()
			let store = try makeSwiftDataLog(deviceId: phone, directory: directory)
			let fixture = try AthleteScopedCoachingFixture(store: store)
			try fixture.secrets.delete(.intervalsConnection)
			let legacy = try StoredAthleteRecord(
				record: fixture.record(
					1, account: .unconnected,
					body: .synced(.dailyNote(DailyNoteBody(note: "M1_UNBOUND_FACT")))))
			legacy.envelopeVersion = 1
			legacy.account = nil
			legacy.bodyVersion = 1
			legacy.body = Data(#"{"dailyNote":{"_0":{"note":"M1_UNBOUND_FACT"}}}"#.utf8)
			let m1 = try legacy.decode().get()
			try await seed(store, [m1])
			let before = await fixture.open()
			fixture.transport.respond = ScriptedReply.sequence(
				[
					.toolCall(
						name: "memory_write",
						arguments: #"{"type":"daily","content":"SKIPPED_UNBOUND_FACT"}"#),
					.finish(reason: .toolCalls), .text("Fact saved."), .finish(reason: .stop),
				], otherwise: { _ in ScriptedReply([.finish(reason: .stop)]) })
			#expect(
				replyText(try await before.sendAndSettle("Remember this before connecting"))
					== "Fact saved.")
			let unbound = try await store.fetch(RecordQuery(scope: .synced([.dailyNote]))).records
			#expect(unbound.count == 2)
			#expect(unbound.allSatisfy { $0.account == .unconnected })
			try assertUnbound(
				in: await fixture.read(using: before), fixture: fixture, included: true)
			try await fixture.connect(.athleteA, using: before)
			try assertUnbound(
				in: await fixture.read(using: before), fixture: fixture, included: true)
			await before.lifecycle(.willTerminate)
			let reopened = try makeSwiftDataLog(deviceId: phone, directory: directory)
			let after = await fixture.open(store: reopened)
			try assertUnbound(
				in: await fixture.read(using: after), fixture: fixture, included: true)
			try await fixture.connect(.rotatedA, using: after)
			try assertUnbound(
				in: await fixture.read(using: after), fixture: fixture, included: true)
			try fixture.peer.replace(.athleteB)
			await after.lifecycle(.becameActive)
			try assertUnbound(
				in: await fixture.read(using: after), fixture: fixture, included: false)
			#expect(
				try await reopened.fetch(RecordQuery(scope: .synced([.dailyNote]))).records
					== unbound)
			await after.lifecycle(.willTerminate)
		}

		@Test func connectionWithoutATurnBindsMemory() async throws {
			let store = InMemoryRecordLog()
			let fixture = try AthleteScopedCoachingFixture(store: store)
			try fixture.secrets.delete(.intervalsConnection)
			try await seed(
				store,
				[
					fixture.record(
						1, account: .unconnected,
						body: .synced(.dailyNote(DailyNoteBody(note: "FIRST_A_FACT"))))
				])
			let before = await fixture.open()
			try await fixture.connect(.athleteA, using: before)
			try fixture.peer.replace(.athleteB)
			await before.lifecycle(.willTerminate)
			let after = await fixture.open()
			await after.lifecycle(.becameActive)
			let b = try await fixture.read(using: after)
			fixture.assertAbsent("FIRST_A_FACT", from: b)
			try await fixture.connect(.athleteA, using: after)
			let a = try await fixture.read(using: after)
			#expect(try fixture.toolText("memory_query", in: a).contains("FIRST_A_FACT"))
			await after.lifecycle(.willTerminate)
		}

		@Test(arguments: [false, true])
		func observationFailureWithholdsModelRequest(acknowledgmentLost: Bool) async throws {
			let store = InMemoryRecordLog()
			let faults = FaultInjectingRecordLog(wrapping: store)
			let fixture = try AthleteScopedCoachingFixture(store: faults)
			try await seed(
				store,
				[
					fixture.record(
						1, account: .unconnected,
						body: .synced(.dailyNote(DailyNoteBody(note: "RETAINED_UNBOUND_FACT"))))
				])
			let coach = await fixture.open()
			let original = try fixture.secrets.intervalsConnection()
			faults.failSyncedAcknowledgments = acknowledgmentLost
			if !acknowledgmentLost { try faults.failAppends(ofKind: "trainingIdentityObserved") }
			let statuses = await coach.observeStatus()
			try #require(
				try await statuses.status {
					$0.training.notice?.key == Catalog.coachHistoryDiskFull
				} != nil)
			#expect(fixture.transport.requests.count == 0)
			faults.failSyncedAcknowledgments = false
			if !acknowledgmentLost {
				let failed = try await coach.sendAndSettle("Read after the storage failure")
				#expect(turnNotice(of: failed)?.key == Catalog.coachHistoryDiskFull)
				#expect(fixture.transport.requests.count == 0)
			}
			#expect(try fixture.secrets.intervalsConnection() == original)
			await coach.lifecycle(.willTerminate)
			let recovered = await fixture.open(store: store)
			let request = try await fixture.read(using: recovered)
			#expect(
				try fixture.toolText("memory_query", in: request).contains("RETAINED_UNBOUND_FACT"))
			let markers = try await store.fetch(
				RecordQuery(scope: .synced([.trainingIdentityObserved]))
			).records
			#expect(markers.count == 1)
			await recovered.lifecycle(.willTerminate)
		}

		@Test func compactionKeepsIndependentAthleteWindows() async throws {
			let fixture = try AthleteScopedCoachingFixture(store: InMemoryRecordLog())
			try await fixture.seedInformation("A_ONLY", account: fixture.accountA, offset: 0)
			let padding = String(repeating: "b", count: historyBudget(clock: fixture.clock) * 5)
			try await fixture.seedInformation(
				"B_ONLY", account: fixture.accountB, offset: 20, reply: "B_ONLY_REPLY " + padding)
			let coach = await fixture.open()
			try await fixture.connect(.athleteB, using: coach)
			fixture.transport.respond = ScriptedReply.sequence(
				[.text("B_ONLY_COMPACTED"), .finish(reason: .stop)], for: .summary,
				otherwise: { _ in ScriptedReply([.text("B reply."), .finish(reason: .stop)]) })
			#expect(replyText(try await coach.sendAndSettle("Compact B history")) == "B reply.")
			let summary = try #require(sent(.droppedSummary, by: fixture.transport).first)
			#expect(summary.messages.contains { $0.content.contains("B_ONLY_REPLY") })
			fixture.assertAbsent("A_ONLY", from: summary)
			for flush in sent(.memoryFlush, by: fixture.transport) {
				fixture.assertAbsent("A_ONLY", from: flush)
			}
			await coach.lifecycle(.willTerminate)
			let reopened = await fixture.open()
			try await fixture.connect(.rotatedA, using: reopened)
			let a = try await fixture.read(using: reopened)
			try fixture.assertInformation("A_ONLY", excluding: "B_ONLY", in: a)
			await reopened.lifecycle(.willTerminate)
		}

		@Test func peerUnboundMemoryRequiresItsOwnOriginBinding() async throws {
			let store = ImportingRecordLog()
			let fixture = try AthleteScopedCoachingFixture(store: store)
			let peer = DeviceID(rawValue: "unbound-import-phone")
			try await seed(
				store,
				[
					fixture.record(
						1, account: .unconnected,
						body: .synced(.dailyNote(DailyNoteBody(note: "PEER_UNBOUND_FACT"))),
						device: peer)
				])
			let coach = await fixture.open()
			let before = try await fixture.read(using: coach)
			fixture.assertAbsent("PEER_UNBOUND_FACT", from: before)
			try await seed(
				store,
				[
					fixture.record(
						2, account: fixture.accountA,
						body: .synced(.trainingIdentityObserved), device: peer)
				])
			store.notifyImport()
			let after = try await fixture.read(using: coach)
			#expect(try fixture.toolText("memory_query", in: after).contains("PEER_UNBOUND_FACT"))
			try await fixture.connect(.athleteB, using: coach)
			fixture.assertAbsent("PEER_UNBOUND_FACT", from: try await fixture.read(using: coach))
			await coach.lifecycle(.willTerminate)
		}

		@Test func unverifiedHistoryStaysExcludedFromUnconnectedCoaching() async throws {
			let fixture = try AthleteScopedCoachingFixture(store: InMemoryRecordLog())
			try fixture.secrets.delete(.intervalsConnection)
			let unknown = TrainingAccount.intervals(connection: ConnectionID(), athlete: nil)
			let turn = TurnID(ulid: fixedUlid(1))
			try await seed(
				fixture.store,
				[
					fixture.record(
						1, account: unknown,
						body: .synced(
							sampleUser(chatId: .main, text: "UNVERIFIED_QUESTION", turn: turn))),
					fixture.record(
						2, account: unknown,
						body: .synced(
							sampleReply(chatId: .main, turn: turn, text: "UNVERIFIED_REPLY"))),
					fixture.record(
						3, account: unknown,
						body: .synced(
							.compactionSummary(
								CompactionSummaryBody(
									chatId: .main,
									markdown: "UNVERIFIED_SUMMARY")))),
				])
			let coach = await fixture.open()
			fixture.transport.respond = { _ in
				ScriptedReply([.text("Unconnected reply."), .finish(reason: .stop)])
			}
			#expect(
				replyText(try await coach.sendAndSettle("UNBOUND_QUESTION")) == "Unconnected reply."
			)
			let unconnected = try await fixture.read(using: coach)
			fixture.assertAbsent("UNVERIFIED", from: unconnected)
			#expect(unconnected.messages.contains { $0.content.contains("UNBOUND_QUESTION") })
			#expect(unconnected.messages.contains { $0.content.contains("Unconnected reply.") })
			try await fixture.connect(.athleteA, using: coach)
			let connected = try await fixture.read(using: coach)
			fixture.assertAbsent("UNVERIFIED", from: connected)
			fixture.assertAbsent("UNBOUND_QUESTION", from: connected)
			await coach.lifecycle(.willTerminate)
		}

		private func assertUnbound(
			in request: CompletionRequest, fixture: AthleteScopedCoachingFixture,
			included: Bool
		) throws {
			let system = try #require(request.messages.first { $0.role == .system }).content
			let query = try fixture.toolText("memory_query", in: request)
			for fact in ["M1_UNBOUND_FACT", "SKIPPED_UNBOUND_FACT"] {
				#expect(system.contains(fact) == included)
				#expect(query.contains(fact) == included)
			}
		}
	}

}
