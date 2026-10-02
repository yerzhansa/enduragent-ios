import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

@Suite struct ResetAdmissionTests {
	@Test func slashStartReturnsWhileTheEarlierReplyIsHeld() async throws {
		let store = InMemoryRecordLog()
		let held = HeldAppendLog(inner: store, holding: "turnSettled", occurrence: 1)
		defer { held.release() }
		let transport = FakeModelTransport()
		transport.respond = ScriptedReply.sequence(
			[.text("Old answer"), .finish(reason: .stop), .text("New answer"), .finish(reason: .stop)],
			otherwise: transport.respond)
		let coach = await makeCoach(transport: transport, store: held)
		let first = try #require(try await coach.send(draft("Old question"), to: .main).acceptedTurn)
		let reached = try await beforeDeadline(within: .hangGuard) {
			var events = held.reached.makeAsyncIterator()
			return await events.next() != nil
		}
		try #require(reached == true)
		let admitted = try await beforeDeadline(within: .subject(.seconds(1)), onTimeout: held.release) {
			try await coach.send(draft("/start"), to: .main)
		}
		try #require(admitted != nil, "New conversation must return admission while the earlier reply is held")
		let next = try #require(try await coach.send(draft("New question"), to: .main).acceptedTurn)
		let waiting = try #require(await coach.currentSnapshot(.main))
		#expect(waiting.turns.map(\.id) == [first])
		let phrasebook = CatalogPhrasebook(tag: .en)
		if case .working(let label) = waiting.activity {
			#expect(phrasebook.say(label, [:]) == "Starting a new conversation…")
		} else {
			Issue.record("The waiting conversation must have one working row")
		}
		held.release()
		let opened = try await firstSnapshot(in: await coach.observe(.main), within: .subject(.seconds(1))) {
			$0.opening.showsWelcome && $0.turns.map(\.id) == [next]
		}
		try #require(opened != nil)
		_ = try #require(await coach.settledState(of: next, in: .main, within: .hangGuard))
		let history = try #require(try await coach.history().first?.id)
		#expect(try await coach.archivedConversation(history)?.turns.map(\.id) == [first])
		let prompt = try #require(sent(.chatAttempt, by: transport).last)
		#expect(!prompt.messages.contains { $0.unstampedContent == "Old question" })
		#expect(prompt.messages.contains { $0.unstampedContent == "New question" })
	}
}
