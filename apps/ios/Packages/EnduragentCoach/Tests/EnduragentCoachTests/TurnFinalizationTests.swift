import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

extension SwiftDataSuites {
	@Suite struct TurnFinalizationTests {
		let transport = FakeModelTransport()
		let intervals = FakeIntervalsClient(athleteName: "Ada", ftp: 250)
		let host = ImmediateExecutionHost()
		let device = DeviceID(rawValue: "finalization-phone")
		let frenchFallback =
			"J’ai atteint ma limite d’étapes en recueillant les données — demande-moi de continuer et je reprendrai là où je me suis arrêté."
		let englishFallback =
			"I ran out of steps gathering data — ask me to continue and I'll pick up where I left off."

		@Test(arguments: ["Les données sont prêtes.", "", " \n\t"], [false, true])
		func finalizationSettlesDurably(finalText: String, commitsMemory: Bool) async throws {
			let directory = try TestTemporaryFolders.make()
			let fixture = try FixtureRecordStore(directory: directory, deviceId: device)
			transport.respond = ScriptedReply.sequence(
				script(finalText, commitsMemory: commitsMemory))
			let coach = await makeCoach(
				transport: transport, intervals: intervals, store: fixture.faults.log, host: host)
			try await coach.setLanguage(.fixed(.fr))
			let settled = try await coach.sendAndSettle("Recueille mes données")
			let snapshot = try #require(await coach.currentSnapshot(.main))
			let turn = try #require(snapshot.turns.first?.id)
			let french = await coach.languagePreference().phrasebook(device: .en)
			let empty = finalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
			let expected = empty ? frenchFallback : finalText
			guard case .completed(let completed) = settled else {
				Issue.record("Expected a completed finalization, got \(settled)")
				return
			}
			#expect(
				completed.reply
					== (empty ? .catalog(Catalog.coachFallbackStepLimit) : .model(finalText)))
			#expect(visibleReply(settled, in: french) == expected)
			#expect(
				ReplyParser.foundation.document(try #require(visibleReply(settled, in: french)))
					.accessibilityText == expected)
			#expect(!settled.retryable)
			#expect(snapshot.liveReply == nil)
			let lease = try #require(await host.ended(0, within: .hangGuard))
			#expect(
				lease.ending
					== .finished(CompletionNotice(reply: expected, turn: turn, language: .fr)))
			try #require(transport.requests.count == 11)
			#expect(
				transport.requests.map(\.charge) == Array(repeating: .chatAttempt, count: 10) + [
					.stepRecovery
				])
			#expect(transport.requests.prefix(10).allSatisfy { !$0.tools.isEmpty })
			let finalization = try #require(transport.requests.last)
			#expect(finalization.tools.isEmpty)
			#expect(finalization.messages.last?.content == "summarize what you did and what's left")
			#expect(finalization.messages.filter { $0.role == .tool }.count == 10)
			#expect(Set(transport.requests.map(\.attempt)).count == 1)
			let writes = try await fixture.faults.log.fetch(
				RecordQuery(scope: .synced([.memorySection, .journal, .provenance]))
			).records
			#expect(
				writes.filter { $0.body.kind == "memorySection" }.count == (commitsMemory ? 1 : 0))
			let memory = try await coach.memory.prompt().view
			if commitsMemory {
				#expect(memory.sections["schedule"]?.contains("Group ride on Saturdays.") == true)
			}
			await coach.lifecycle(.willTerminate)
			let reopened = try FixtureRecordStore(directory: directory, deviceId: device)
			let relaunched = await makeCoach(
				transport: transport, intervals: intervals, store: reopened.faults.log)
			let restored = try #require(await relaunched.currentSnapshot(.main))
			let restoredTurn = try #require(restored.turns.first)
			#expect(restoredTurn.id == turn)
			#expect(restoredTurn.state == settled)
			let restoredFrench = await relaunched.languagePreference().phrasebook(device: .en)
			#expect(restoredFrench.tag == .fr)
			#expect(visibleReply(restoredTurn.state, in: restoredFrench) == expected)
			#expect(try await relaunched.memory.prompt().view == memory)
			#expect(transport.requests.count == 11)
			await #expect(throws: RetryRefusal.alreadyAnswered) {
				try await relaunched.retry(turn, in: .main)
			}
			#expect(transport.requests.count == 11)
			#expect(
				try await reopened.faults.log.fetch(
					RecordQuery(scope: .synced([.memorySection, .journal, .provenance]))
				).records == writes)
			transport.respond = ScriptedReply.sequence([
				.text("Continuons."), .finish(reason: .stop),
			])
			_ = try await relaunched.sendAndSettle("Continue")
			let next = try #require(transport.requests.last)
			#expect(
				next.messages.filter { $0.role == .assistant }.map(\.content) == [
					empty ? englishFallback : finalText
				])
		}

		private func visibleReply(_ state: TurnState, in phrasebook: CatalogPhrasebook) -> String? {
			guard case .completed(let completed) = state else { return nil }
			return completed.reply.sentence(in: phrasebook)
		}

		private func script(_ finalText: String, commitsMemory: Bool) -> [ScriptedEvent] {
			var events: [ScriptedEvent] = []
			for step in 0..<10 {
				if commitsMemory, step == 0 {
					events.append(
						.toolCall(
							name: "memory_write",
							arguments:
								#"{"type":"memory","section":"schedule","content":"Group ride on Saturdays."}"#
						))
				} else {
					events.append(
						.toolCall(name: "intervals_fetch_activities", arguments: #"{"days":7}"#))
				}
				events.append(.finish(reason: .toolCalls))
			}
			events += [.text(finalText), .finish(reason: .stop)]
			return events
		}
	}
}
