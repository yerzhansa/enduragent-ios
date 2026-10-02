import EnduragentCoach
import EnduragentCoachFixtures
import Testing

@testable import Enduragent

extension FixtureLaunchTests {
	@Test func bufferedTextClosesBeforeLanguagePicker() async throws {
		var launch = launch
		launch.coalescing = CoalescingPolicy(window: .seconds(60))
		let services = try fixtureServices(launch, defaults: defaults)
		let transport = try #require(services.fixtureTransport)
		let model = model(services)
		await model.agreeAndStartChatting()
		model.draft.text = "fixture:slow"
		await model.send()
		let accepted = try await firstTurn(model)
		#expect(transport.requestCount == 0)
		model.draft.text = "/language"
		await model.send()
		#expect(model.showLanguage)
		#expect(model.draft.text.isEmpty)
		#expect(!model.notSent)
		try await until {
			transport.requestCount == 1 && model.chat?.turns.first?.state.isSettled == false
		}
		#expect(model.chat?.turns.map(\.id) == [accepted.id])
		#expect(model.chat?.turns.map(\.athleteText) == ["fixture:slow"])
		model.showLanguage = false
		let completed = try await settledTurn(model)
		#expect(completed.id == accepted.id)
		#expect(replyText(completed.state) == FirstWeekFixture.weekSummary)
		#expect(!model.isWorking)
		#expect(transport.requestCount == 1)
	}
}
