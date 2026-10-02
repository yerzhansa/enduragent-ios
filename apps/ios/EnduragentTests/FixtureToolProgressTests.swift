import EnduragentCoach
import EnduragentCoachFixtures
import Foundation
import Testing

@testable import Enduragent

extension FixtureLaunchTests {
	@Test func historyDuringTheToolReadKeepsTheQuestionReplyAndReview() async throws {
		let services = try services()
		let transport = try #require(services.fixtureTransport)
		let intervals = try #require(services.fixture?.intervals)
		let model = model(services)
		await model.agreeAndStartChatting()
		model.connectKey = "fixture"
		await model.connect()
		try #require(model.didConnect)
		model.draft.text = FirstWeekFixture.toolProgressDirective
		await model.send()
		let accepted = try await firstTurn(model)
		#expect(accepted.athleteText == "fixture:slow-tool")
		#expect(model.draft.text.isEmpty)
		#expect(model.isWorking)
		#expect(model.chat?.liveReply?.text.isEmpty ?? true)
		#expect(!intervals.calls.contains(.activities(days: 7)))
		try await until { intervals.calls.contains(.activities(days: 7)) }
		try await until { model.chat?.liveReply?.text == "Checking your recent rides. " }
		#expect(model.chat?.turns.map(\.id) == [accepted.id])
		#expect(model.isWorking)
		#expect(model.chat?.turns.first?.state.isSettled == false)
		#expect(transport.requestCount == 1)
		model.open(.history)
		await model.loadHistory()
		#expect(model.navigation == [.history])
		#expect(model.history == .loaded([]))
		#expect(model.isWorking)
		#expect(transport.requestCount == 1)
		model.navigation.removeAll()
		#expect(model.chat?.turns.map(\.id) == [accepted.id])
		#expect(model.chat?.liveReply?.text == "Checking your recent rides. ")
		#expect(model.isWorking)
		let settled = try await settledTurn(model)
		#expect(settled.id == accepted.id)
		#expect(settled.athleteText == "fixture:slow-tool")
		#expect(
			replyText(settled.state)
				== "I've prepared the ride. Confirm to add it.")
		#expect(!model.isWorking)
		let review = try #require(model.chat?.review)
		#expect(review.ref.chat == .main)
		#expect(
			review.cards.map { $0.name.sentence(in: model.phrasebook) } == ["Endurance with tempo"])
		#expect(review.cards.map(\.date) == ["1998-06-16"])
		#expect(review.totals.additions == 1)
		#expect(transport.requestCount == 3)
		#expect(intervals.events.isEmpty)
	}
}
