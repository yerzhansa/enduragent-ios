import EnduragentCoachFixtures
import Foundation
import Synchronization
import Testing

@testable import EnduragentCoach

@Suite struct FragmentOrderingTests {
	@Test func fragmentsExtendTheRealTrailingWindow() async throws {
		let sleeps = Mutex(0)
		let timer = HeldClock { _ in sleeps.withLock { $0 += 1 } }
		let transport = FakeModelTransport()
		transport.respond = ScriptedReply.sequence([
			.text("Combined reply."), .finish(reason: .stop),
			.text("Separate reply."), .finish(reason: .stop),
		])
		let coach = await makeCoach(
			transport: transport, store: InMemoryRecordLog(), clock: timer,
			coalescing: .npm, coalescingClock: timer)
		let first = try #require(try await coach.send(draft("Thursday?"), to: .main).acceptedTurn)
		try await waitUntil { sleeps.withLock { $0 } == 1 }
		timer.advance(by: .milliseconds(1_400))
		#expect(try await coach.send(draft("Friday?"), to: .main) == .accepted(first))
		try await waitUntil { sleeps.withLock { $0 } == 2 }
		timer.advance(by: .milliseconds(100))
		try await expectCollecting(coach, first, until: timer.now.addingTimeInterval(1.4))
		#expect(transport.requestCount == 0)
		timer.advance(by: .milliseconds(1_300))
		#expect(try await coach.send(draft("Saturday?"), to: .main) == .accepted(first))
		try await waitUntil { sleeps.withLock { $0 } == 3 }
		timer.advance(by: .milliseconds(100))
		try await expectCollecting(coach, first, until: timer.now.addingTimeInterval(1.4))
		timer.advance(by: .milliseconds(1_300))
		#expect(transport.requestCount == 0)
		timer.advance(by: .milliseconds(100))
		#expect(
			replyText(try #require(await coach.settledState(of: first, in: .main)))
				== "Combined reply.")
		let combined = try #require(await coach.currentSnapshot(.main))
		#expect(combined.turns.map(\.athleteText) == ["Thursday?\nFriday?\nSaturday?"])
		#expect(transport.requestCount == 1)
		#expect(
			transport.requests.first?.messages.last?.unstampedContent.hasPrefix(
				"Thursday?\nFriday?\nSaturday?\nCurrent time: ") == true)
		timer.advance(by: .milliseconds(100))
		let separate = try #require(try await coach.send(draft("Sunday?"), to: .main).acceptedTurn)
		#expect(separate != first)
		try await waitUntil { sleeps.withLock { $0 } == 4 }
		#expect(transport.requestCount == 1)
		timer.advance(by: .milliseconds(1_500))
		#expect(
			replyText(try #require(await coach.settledState(of: separate, in: .main)))
				== "Separate reply.")
		let completed = try #require(await coach.currentSnapshot(.main))
		#expect(completed.turns.map(\.id) == [first, separate])
		#expect(completed.turns.map(\.athleteText) == ["Thursday?\nFriday?\nSaturday?", "Sunday?"])
		#expect(
			completed.turns.compactMap { replyText($0.state) } == [
				"Combined reply.", "Separate reply.",
			])
		#expect(transport.requestCount == 2)
		#expect(
			transport.requests.last?.messages.last?.unstampedContent.hasPrefix(
				"Sunday?\nCurrent time: ") == true)
	}

	@Test(arguments: [SlashCommand.review, .start, .language])
	func shortcutsCloseBufferedTextInSendOrder(_ command: SlashCommand) async throws {
		let timer = HeldClock()
		let replies = HeldClock()
		let transport = FakeModelTransport(clock: replies)
		transport.respond = { request in
			guard request.purpose == .chat else { return ScriptedReply([.finish(reason: .stop)]) }
			return ScriptedReply(
				[
					.text(request.text == "Thursday?" ? "First reply." : "Next reply."),
					.finish(reason: .stop),
				], requestDelay: .seconds(10))
		}
		let coach = await makeCoach(
			transport: transport, store: InMemoryRecordLog(), clock: timer,
			coalescing: .npm, coalescingClock: timer)
		let first = try #require(try await coach.send(draft("Thursday?"), to: .main).acceptedTurn)
		try await timer.waitUntilHeld(.milliseconds(1_500))
		let outcome = try await coach.send(draft(command.rawValue), to: .main)
		try await replies.waitUntilHeld(.seconds(10))
		let processing = try #require(
			try await firstSnapshot(in: await coach.observe(.main), within: .hangGuard) {
				if case .processing? = $0.turns.first?.state { return true }
				return false
			})
		#expect(processing.turns.first?.id == first)
		#expect(processing.turns.first?.athleteText == "Thursday?")
		#expect(sent(.chatAttempt, by: transport).count == 1)
		if command == .start {
			guard case .newConversation(let admission) = outcome else {
				Issue.record("Expected reset admission")
				return
			}
			replies.release(.seconds(10))
			#expect(await coach.resetCompletion(admission, in: .main) == .started(memory: .saved))
			let ref = try #require(try await coach.history().first?.id)
			let archived = try #require(try await coach.archivedConversation(ref))
			#expect(archived.turns.map(\.athleteText) == ["Thursday?"])
			#expect(archived.turns.compactMap { replyText($0.state) } == ["First reply."])
			#expect(sent(.chatAttempt, by: transport).count == 1)
			#expect(
				sent(.memoryFlush, by: transport).first?.messages.contains {
					$0.content == "First reply."
				} == true)
			return
		}
		let next: TurnID
		let nextText: String
		if command == .language {
			#expect(outcome == .showLanguagePicker)
			nextText = "Sunday?"
			next = try #require(try await coach.send(draft(nextText), to: .main).acceptedTurn)
		} else {
			nextText = "/review"
			next = try #require(outcome.acceptedTurn)
		}
		#expect(next != first)
		try await timer.waitUntilHeld(.milliseconds(1_500))
		timer.advance(by: .milliseconds(1_500))
		let queued = try #require(
			try await firstSnapshot(in: await coach.observe(.main), within: .hangGuard) {
				$0.turns.last?.state == .accepted(.queued(position: 2))
			})
		#expect(queued.turns.map(\.athleteText) == ["Thursday?", nextText])
		#expect(sent(.chatAttempt, by: transport).count == 1)
		replies.release(.seconds(10))
		#expect(
			replyText(try #require(await coach.settledState(of: first, in: .main)))
				== "First reply.")
		try await replies.waitUntilHeld(.seconds(10))
		replies.release(.seconds(10))
		#expect(
			replyText(try #require(await coach.settledState(of: next, in: .main))) == "Next reply.")
		let completed = try #require(await coach.currentSnapshot(.main))
		#expect(completed.turns.map(\.id) == [first, next])
		#expect(
			completed.turns.compactMap { replyText($0.state) } == ["First reply.", "Next reply."])
		let requests = sent(.chatAttempt, by: transport)
		try #require(requests.count == 2)
		#expect(
			requests[0].messages.last?.unstampedContent.hasPrefix("Thursday?\nCurrent time: ")
				== true)
		#expect(
			requests[1].messages.last?.unstampedContent.hasPrefix(nextText + "\nCurrent time: ")
				== true)
	}

	private func expectCollecting(_ coach: Coach, _ turn: TurnID, until deadline: Date) async throws
	{
		let snapshot = try #require(
			try await firstSnapshot(in: await coach.observe(.main), within: .hangGuard) { _ in true
			})
		#expect(snapshot.turns.first?.id == turn)
		#expect(snapshot.turns.first?.state == .accepted(.collecting(until: deadline)))
	}
}
