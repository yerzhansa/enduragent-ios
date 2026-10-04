import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

extension SwiftDataSuites {
	@Suite(.timeLimit(.minutes(2))) struct AthleteScopedExtractionTests {
		@Test(arguments: [false, true])
		func delayedExtractionKeepsSourceAthlete(relaunch: Bool) async throws {
			let directory = try TestTemporaryFolders.make()
			let phone = DeviceID(rawValue: "extraction-source-phone")
			let store = try makeSwiftDataLog(deviceId: phone, directory: directory)
			let fixture = try AthleteScopedExtractionFixture(store: store)
			let base = fixture.base
			try await base.seedInformation("A_ONLY", account: base.accountA, offset: 0)
			try await base.seedInformation("B_ONLY", account: base.accountB, offset: 20)
			try await seed(
				store,
				[
					base.record(
						40, account: base.accountB,
						body: .synced(
							.ledgerEvent(
								LedgerEventBody(
									date: "1998-06-13", kind: .decision, text: "SHARED_EVENT",
									source: .flush))))
				])
			try await seedHistory(
				store, clock: base.clock, turns: 3,
				tokens: historyBudget(clock: base.clock) * 9 / 10)
			fixture.scriptExtraction()
			let held = HeldExtractionTransport(base.transport)
			defer { held.release() }
			let before = await fixture.open(transport: held)
			#expect(
				replyText(try await before.sendAndSettle("Schedule extraction")) == "Reply saved.")
			try await waitUntil { held.isHeld }
			try base.peer.replace(.athleteB)
			await before.lifecycle(.becameActive)
			let after: Coach
			let active: any RecordLog
			if relaunch {
				await before.lifecycle(.willTerminate)
				active = try makeSwiftDataLog(deviceId: phone, directory: directory)
				after = await fixture.open(store: active)
				await after.lifecycle(.becameActive)
			} else {
				active = store
				after = before
				held.release()
			}
			try await waitForRecords(.deviceLocal([.flushSettled]), count: 1, in: active)
			try await fixture.assertMemory(
				"A", excluding: "B", account: base.accountA, coach: after)
			let b = try await after.memory.fullContext(for: base.accountB)
			#expect(b.contains("B_ONLY_FACT"))
			#expect(!b.contains("A_EXTRACTED"))
			let events = try await active.fetch(RecordQuery(scope: .synced([.ledgerEvent]))).records
			#expect(
				events.filter {
					if case .synced(.ledgerEvent(let body)) = $0.body {
						return body.text == "SHARED_EVENT"
					}
					return false
				}.count == 2)
			for request in sent(.memoryFlush, by: base.transport) {
				#expect(request.messages.contains { $0.content.contains("A_ONLY_FACT") })
				base.assertAbsent("B_ONLY", from: request)
			}
			let extracted = try await active.fetch(
				RecordQuery(scope: .synced([.memorySection, .journal]))
			).records
			#expect(
				extracted.filter {
					if case .operation(.memoryFlush, _) = $0.cause { return true }
					return false
				}.allSatisfy { $0.account == base.accountA })
			await after.lifecycle(.willTerminate)
		}

		@Test func newConversationPartitionsSources() async throws {
			let fixture = try AthleteScopedExtractionFixture()
			let base = fixture.base
			try await base.seedInformation("A_ONLY", account: base.accountA, offset: 0)
			try await base.seedInformation("B_ONLY", account: base.accountB, offset: 20)
			try await fixture.seedRows("A_SOURCE", account: base.accountA, start: 40)
			try await fixture.seedRows("B_SOURCE", account: base.accountB, start: 50)
			fixture.scriptExtraction()
			let coach = await fixture.open()
			try await base.connect(.athleteB, using: coach)
			#expect(await coach.resetAndSettle(in: .main) == .started(memory: .saved))
			try await fixture.assertMemory(
				"A", excluding: "B", account: base.accountA, coach: coach)
			try await fixture.assertMemory(
				"B", excluding: "A", account: base.accountB, coach: coach)
			let firstSteps = sent(.memoryFlush, by: base.transport).filter {
				$0.messages.allSatisfy { $0.role != .tool }
			}
			#expect(firstSteps.count == 2)
			for request in firstSteps {
				let isA = request.messages.contains { $0.content.contains("A_SOURCE_QUESTION") }
				#expect(
					request.messages.contains {
						$0.content.contains(isA ? "A_ONLY_FACT" : "B_ONLY_FACT")
					})
				base.assertAbsent(isA ? "B_ONLY" : "A_ONLY", from: request)
				base.assertAbsent(isA ? "B_SOURCE" : "A_SOURCE", from: request)
			}
			#expect(try await fixture.jobs().allSatisfy { $0.saved })
			await coach.lifecycle(.willTerminate)
		}

		@Test func inTurnExtractionUsesAttemptSource() async throws {
			let fixture = try AthleteScopedExtractionFixture()
			let base = fixture.base
			try await base.seedInformation("B_ONLY", account: base.accountB, offset: 20)
			fixture.scriptExtraction()
			base.transport.respond = ScriptedReply.sequence(
				[
					.fail(.http(status: 400, body: "maximum context length is 8192 tokens")),
					.text("Rescued reply."), .finish(reason: .stop),
				], for: .chat, otherwise: base.transport.respond)
			let coach = await fixture.open()
			#expect(
				replyText(try await coach.sendAndSettle("A_CURRENT_QUESTION")) == "Rescued reply.")
			let flush = try #require(sent(.memoryFlush, by: base.transport).first)
			#expect(flush.messages.contains { $0.unstampedContent == "A_CURRENT_QUESTION" })
			base.assertAbsent("B_ONLY", from: flush)
			try await base.connect(.athleteB, using: coach)
			try await fixture.assertMemory(
				"A", excluding: "B", account: base.accountA, coach: coach)
			#expect(try await coach.memory.fullContext(for: base.accountB).contains("B_ONLY_FACT"))
			await coach.lifecycle(.willTerminate)
		}

		@Test func tryAgainCreatesNewAthleteRows() async throws {
			let fixture = try AthleteScopedExtractionFixture()
			let base = fixture.base
			try await base.seedInformation("A_ONLY", account: base.accountA, offset: 0)
			try await base.seedInformation("B_ONLY", account: base.accountB, offset: 20)
			let before = await fixture.open()
			base.transport.respond = { _ in ScriptedReply([.text("A_OLD_PARTIAL"), .hang]) }
			let turn = try #require(
				try await before.send(draft("Repeat this question"), to: .main).acceptedTurn)
			await before.waitForLiveText(turn)
			await before.stop(.main)
			try #require(
				turnNotice(of: try #require(await before.settledState(of: turn, in: .main)))?
					.actions
					== [.tryAgain(turn)])
			let firstAttempt = try await base.store.fetch(
				RecordQuery(scope: .synced([.attemptQuestion, .turnSettled]), turn: turn)
			).records
			try await base.connect(.athleteB, using: before)
			fixture.scriptExtraction()
			base.transport.respond = ScriptedReply.sequence(
				[.text("B_NEW_REPLY"), .finish(reason: .stop)], for: .chat,
				otherwise: base.transport.respond)
			try await before.retry(turn, in: .main)
			#expect(
				replyText(try #require(await before.settledState(of: turn, in: .main)))
					== "B_NEW_REPLY")
			let request = try #require(sent(.chatAttempt, by: base.transport).last)
			base.assertAbsent("A_ONLY", from: request)
			base.assertAbsent("A_OLD_PARTIAL", from: request)
			#expect(request.messages.contains { $0.content.contains("B_ONLY_FACT") })
			await before.lifecycle(.willTerminate)
			let coach = await fixture.open()
			let ledger = Ledger(
				log: base.store, clock: base.clock, diagnostics: DiagnosticsLog(clock: base.clock))
			let conversation = try await ledger.conversation(.main)
			let facts = try #require(conversation.turn(turn))
			#expect(facts.userRow?.account == base.accountA)
			let rows = facts.messageRows(using: conversation.ownership)
			#expect(
				rows.filter { $0.account.authority(under: base.accountA) == .same }.map(
					\.message.text) == ["Repeat this question", "A_OLD_PARTIAL"])
			#expect(
				rows.filter { $0.account.authority(under: base.accountB) == .sameAthlete }.map(
					\.message.text) == ["Repeat this question", "B_NEW_REPLY"])
			let saved = try await base.store.fetch(
				RecordQuery(scope: .synced([.attemptQuestion, .turnSettled]), turn: turn)
			).records
			#expect(saved.count == 4)
			for record in firstAttempt { #expect(saved.first { $0.ulid == record.ulid } == record) }
			#expect(await coach.resetAndSettle(in: .main) == .started(memory: .saved))
			let flushes = sent(.memoryFlush, by: base.transport).filter {
				$0.messages.allSatisfy { $0.role != .tool }
			}
			#expect(flushes.count == 2)
			for flush in flushes {
				#expect(
					flush.messages.filter { $0.unstampedContent == "Repeat this question" }.count
						== 1)
				let isA = flush.messages.contains { $0.content.contains("A_OLD_PARTIAL") }
				base.assertAbsent(isA ? "B_NEW_REPLY" : "A_OLD_PARTIAL", from: flush)
				base.assertAbsent(isA ? "B_ONLY" : "A_ONLY", from: flush)
			}
			await coach.lifecycle(.willTerminate)
		}

		@Test func unsavedRetryQuestionWithholdsTheModelRequest() async throws {
			let store = InMemoryRecordLog()
			let faults = FaultInjectingRecordLog(wrapping: store)
			let fixture = try AthleteScopedExtractionFixture(store: faults)
			let base = fixture.base
			let coach = await fixture.open()
			base.transport.respond = { _ in ScriptedReply([.fail(.http(status: 400))]) }
			let turn = try #require(
				try await coach.send(draft("Repeat after connecting"), to: .main).acceptedTurn)
			try #require(
				turnNotice(of: try #require(await coach.settledState(of: turn, in: .main)))?.actions
					== [.tryAgain(turn)])
			try await base.connect(.athleteB, using: coach)
			try faults.failAppends(ofKind: "attemptQuestion")
			let calls = base.transport.requests.count
			try await coach.retry(turn, in: .main)
			#expect(
				turnNotice(of: try #require(await coach.settledState(of: turn, in: .main)))?.key
					== Catalog.coachHistoryDiskFull)
			#expect(base.transport.requests.count == calls)
			let questions = try await store.fetch(
				RecordQuery(scope: .synced([.attemptQuestion]), turn: turn)
			).records
			#expect(questions.count == 1)
			#expect(questions.first?.account == base.accountA)
			await coach.lifecycle(.willTerminate)
		}

		@Test(arguments: [false, true])
		func unconnectedSourcesBindFirstAthlete(recovery: Bool) async throws {
			let directory = try TestTemporaryFolders.make()
			let phone = DeviceID(rawValue: "unconnected-extraction-phone")
			let store = try makeSwiftDataLog(deviceId: phone, directory: directory)
			let fixture = try AthleteScopedExtractionFixture(store: store)
			let base = fixture.base
			try base.secrets.delete(.intervalsConnection)
			fixture.scriptExtraction()
			let before = await fixture.open()
			#expect(
				replyText(try await before.sendAndSettle("Unconnected source question"))
					== "Reply saved.")
			if recovery {
				base.transport.respond = { request in
					ScriptedReply(
						request.purpose == .flush
							? [.fail(.http(status: 402))] : [.finish(reason: .stop)])
				}
				#expect(await before.resetAndSettle(in: .main) == .started(memory: .notSaved))
				try await base.connect(.athleteA, using: before)
				try base.peer.replace(.athleteB)
				await before.lifecycle(.willTerminate)
				fixture.scriptExtraction()
			} else {
				#expect(await before.resetAndSettle(in: .main) == .started(memory: .saved))
			}
			let reopened = try makeSwiftDataLog(deviceId: phone, directory: directory)
			let after = recovery ? await fixture.open(store: reopened) : before
			if !recovery {
				try await base.connect(.athleteA, using: after)
				try await base.connect(.athleteB, using: after)
			}
			await after.lifecycle(.becameActive)
			try await waitForRecords(.deviceLocal([.flushSettled]), count: 1, in: reopened)
			#expect(try await fixture.jobs(in: reopened).allSatisfy { $0.saved })
			try await fixture.assertMemory(
				"A", excluding: "B", account: base.accountA, coach: after)
			#expect(
				!((try await after.memory.fullContext(for: base.accountB)).contains("A_EXTRACTED")))
			try await base.connect(.rotatedA, using: after)
			await after.lifecycle(.willTerminate)
			let final = await fixture.open(
				store: try makeSwiftDataLog(deviceId: phone, directory: directory))
			#expect(
				try await final.memory.fullContext(
					for: try #require(base.secrets.intervalsConnection()).account
				).contains("A_EXTRACTED"))
			try await base.connect(.athleteB, using: final)
			#expect(
				!((try await final.memory.fullContext(for: base.accountB)).contains("A_EXTRACTED")))
			await final.lifecycle(.willTerminate)
		}

		@Test func mixedLegacyRecoveryKeepsCompletedPartitions() async throws {
			let fixture = try AthleteScopedExtractionFixture()
			let base = fixture.base
			let a = try await fixture.seedRows("A_SOURCE", account: .unconnected, start: 1)
			let b = try await fixture.seedRows("B_SOURCE", account: base.accountB, start: 10)
			let turn = TurnID(ulid: a[0].ulid)
			guard case .synced(.turnSettled(let settled)) = a[1].body else {
				throw LedgerFailure.rejectedBatch
			}
			let attempt = settled.attempt
			try await seed(
				base.store,
				[
					base.record(
						31, account: base.accountA,
						body: .deviceLocal(
							.turnClaim(
								TurnClaimBody(
									chatId: .main, turn: turn, attempt: attempt,
									process: ProcessID(ulid: fixedUlid(32)), lease: .gracePeriodOnly
								))), cause: .operation(.turn(turn), attempt))
				])
			let parent = FlushJobID(ulid: fixedUlid(40))
			try await seed(
				base.store,
				[
					base.record(
						40, account: base.accountB,
						body: .deviceLocal(
							.flushPending(
								FlushPendingBody(
									chatId: .main, messageUlids: (a + b).map(\.ulid),
									process: ProcessID(ulid: fixedUlid(50))))))
				])
			fixture.scriptExtraction()
			let successful = base.transport.respond
			base.transport.respond = { request in
				if request.purpose == .flush,
					request.userMessages.contains(where: { $0.contains("B_SOURCE") })
				{
					return ScriptedReply([.fail(.http(status: 402))])
				}
				return successful(request)
			}
			try base.peer.replace(.athleteB)
			let before = await fixture.open()
			await before.lifecycle(.becameActive)
			try await waitForRecords(.deviceLocal([.flushSettled]), count: 1, in: base.store)
			try await waitUntil {
				sent(.memoryFlush, by: base.transport).contains {
					$0.messages.contains { $0.content.contains("B_SOURCE_QUESTION") }
				}
			}
			await before.lifecycle(.willTerminate)
			let first = try await fixture.jobs()
			#expect(first.count == 3)
			#expect(first.first { $0.id == parent }?.phase == .pending)
			#expect(first.filter { $0.parent == parent && $0.saved }.count == 1)
			let aRequests = sent(.memoryFlush, by: base.transport).filter {
				$0.messages.contains { $0.content.contains("A_SOURCE_QUESTION") }
			}.count
			fixture.scriptExtraction()
			let after = await fixture.open()
			await after.lifecycle(.becameActive)
			try await waitForRecords(.deviceLocal([.flushSettled]), count: 3, in: base.store)
			#expect(try await fixture.jobs().allSatisfy { $0.saved })
			#expect(
				sent(.memoryFlush, by: base.transport).filter {
					$0.messages.contains { $0.content.contains("A_SOURCE_QUESTION") }
				}.count == aRequests)
			#expect(try await fixture.jobs().count == 3)
			try await fixture.assertMemory(
				"A", excluding: "B", account: base.accountA, coach: after)
			try await fixture.assertMemory(
				"B", excluding: "A", account: base.accountB, coach: after)
			await after.lifecycle(.willTerminate)
		}
	}
}
