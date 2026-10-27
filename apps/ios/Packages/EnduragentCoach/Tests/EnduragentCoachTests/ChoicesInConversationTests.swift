import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

@Suite(.timeLimit(.minutes(1))) struct ChoicesInConversationTests {
	let transport = FakeModelTransport()
	let records = InMemoryRecordLog()
	let intervals = FakeIntervalsClient(athleteName: "Ada", ftp: 250)
	let offer = """
		1. Build endurance. Add easy riding time. This builds stamina with less fatigue. Recommended.
		2. Build speed. Add short hard intervals. This improves speed with more recovery needed.
		"""

	@Test func startAfterUnansweredChoiceArchivesItAndStartsNewConversation() async throws {
		transport.respond = ScriptedReply.sequence([
			.text(offer), .finish(reason: .stop),
			.text("Let's discuss your new question."), .finish(reason: .stop),
		])
		transport.respond = ScriptedReply.sequence(
			[.finish(reason: .stop)], for: .flush, otherwise: transport.respond)
		let coach = await makeCoach(transport: transport, intervals: intervals, store: records)
		let turn = try #require(
			try await coach.send(draft("Offer planning directions."), to: .main).acceptedTurn)
		#expect(replyText(try #require(await coach.settledState(of: turn, in: .main))) == offer)

		guard
			case .newConversation(let admission) = try await coach.send(draft("/start"), to: .main)
		else {
			Issue.record("Expected reset admission")
			return
		}
		#expect(await coach.resetCompletion(admission, in: .main) == .started(memory: .saved))
		let snapshot = try #require(await coach.currentSnapshot(.main))
		#expect(snapshot.turns.isEmpty)
		#expect(snapshot.opening.notice == Catalog.chatNoticeNewConversationSuccess)
		let archive = try #require(try await coach.history().first?.id)
		let archived = try #require(try await coach.archivedConversation(archive))
		#expect(archived.reason == .newConversation)
		#expect(archived.turns.map(\.id) == [turn])
		#expect(replyText(try #require(archived.turns.first?.state)) == offer)

		let next = try #require(
			try await coach.send(draft("A new question."), to: .main).acceptedTurn)
		#expect(
			replyText(try #require(await coach.settledState(of: next, in: .main)))
				== "Let's discuss your new question.")
		let request = try #require(sent(.chatAttempt, by: transport).last)
		#expect(request.messages.map(\.role) == [.system, .user])
		#expect(request.messages.last?.content.hasPrefix("A new question.\nCurrent time:") == true)
		#expect(intervals.calls.filter(\.isWrite).isEmpty)
	}
}
