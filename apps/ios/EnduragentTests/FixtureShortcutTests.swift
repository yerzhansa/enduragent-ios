import EnduragentCoach
import EnduragentCoachFixtures
import Foundation
import Testing

@testable import Enduragent

extension FixtureLaunchTests {
	@Test(arguments: [SlashCommand.workout, .plan, .status])
	func pickedShortcutFillsTheComposerAndSendsNothing(command: SlashCommand) async throws {
		let services = try services()
		let transport = try #require(services.fixtureTransport)
		let model = await connectedModel(services)
		try await observed(model)
		model.draft.text = "/"
		model.draftChanged(from: "")
		try #require(model.slashListVisible)

		model.fillSlash(command)

		#expect(model.draft.text == command.rawValue + " ")
		#expect(!model.slashListVisible)
		#expect(!model.isWorking)
		#expect(model.chat?.turns.isEmpty == true)
		#expect(transport.requestCount == 0)
	}

	@Test(arguments: [
		("/workout 45 minutes indoors", FirstWeekFixture.workoutShortcutReply),
		("/status how is my Form this week", FirstWeekFixture.statusShortcutReply),
		("/plan for my gran fondo in June", FirstWeekFixture.planShortcutReply),
	])
	func sentShortcutShowsItsTextAndWorksUntilTheReplyInText(text: String, reply: String)
		async throws
	{
		let services = try services()
		let transport = try #require(services.fixtureTransport)
		let intervals = try #require(services.fixture?.intervals)
		let model = await connectedModel(services)
		model.draft.text = text
		await model.send()

		let accepted = try await firstTurn(model)
		#expect(accepted.athleteText == text)
		#expect(model.draft.text.isEmpty)
		try await until { transport.requestCount == 1 }
		#expect(model.isWorking)
		#expect(model.chat?.liveReply?.text.isEmpty ?? true)
		#expect(model.chat?.turns.map(\.state.isSettled) == [false])

		let settled = try await settledTurn(model)
		#expect(settled.id == accepted.id)
		#expect(settled.athleteText == text)
		#expect(replyText(settled.state) == reply)
		#expect(!model.isWorking)
		#expect(model.chat?.review == nil)
		#expect(transport.requestCount == 1)
		#expect(intervals.events.isEmpty)
	}

	@Test func workoutLosingModelAccessMidReplyShowsTheNoticeWithTryAgainAndNoReply() async throws {
		let services = try services()
		let transport = try #require(services.fixtureTransport)
		let intervals = try #require(services.fixture?.intervals)
		let model = await connectedModel(services)
		let text = "/workout " + FirstWeekFixture.shortcutLostDirective
		model.draft.text = text
		await model.send()

		let lost = try await settledTurn(model)
		guard case .failed(let failed) = lost.state else {
			Issue.record("expected a failed turn, got \(lost.state)")
			return
		}
		#expect(lost.athleteText == text)
		#expect(failed.notice?.key == Catalog.coachErrorProviderDown)
		#expect(failed.notice?.actions == [.tryAgain(lost.id)])
		#expect(model.chat?.turns.map(\.id) == [lost.id])
		#expect(model.chat?.liveReply == nil)
		#expect(!model.isWorking)
		#expect(model.chat?.review == nil)
		#expect(transport.requestCount == 1)
		#expect(intervals.events.isEmpty)
	}

	private func connectedModel(_ services: AppServices) async -> ShellModel {
		let model = await model(services)
		await model.agreeAndStartChatting()
		model.trainingSettings.edit()
		model.connectKey = "fixture"
		await model.connect()
		#expect(model.didConnect)
		return model
	}
}
