import EnduragentCoach
import EnduragentCoachFixtures
import Testing

@testable import Enduragent

@MainActor
@Suite(.serialized, FixtureTestScope())
struct AccessSettingsTests {
	private let harness = FixtureLaunchTests()

	@Test func creditsSetupPersistsBeforeSelectingAndReopensWithBuiltInModel() async throws {
		do {
			let model = try await open(.openRouterNeedsCredits)
			let fixture = try #require(model.services.fixture)
			try #require(try await model.services.coach.creditsIdentity().hasCreditsKey == false)
			#expect(model.selectedAccessMethod == .openRouterAccount)
			model.open(.settings)
			model.open(.accessMethod)
			await model.chooseAccess(.useCredits)
			try await model.waitForStatus { $0.access.savedMethod == .credits }
			#expect(model.selectedAccessMethod == .credits)
			#expect(model.status.access.availability == .ready)
			#expect(model.accessNotice?.sentence(in: model.displayLocale) == "200 credits")
			#expect(try fixture.secrets.creditsAccount()?.key == FirstWeekFixture.creditsKey)
			#expect(fixture.credits.calls == [.grant])
			await model.acceptConsent()
			try await model.waitForStatus { !$0.needsProviderConsent }
			#expect(
				try fixture.secrets.openRouterAccountKey(at: .legacy)
					== FirstWeekFixture.openRouterKey)
		}
		let reopened = try await harness.reopen()
		#expect(reopened.selectedAccessMethod == .credits)
		#expect(reopened.status.access.availability == .ready)
		try await harness.proveToolTurn(reopened, method: .credits, model: AppServices.builtInModel)
	}

	@Test(arguments: [FixtureCreditsOutcome.provisioningFailed, .alreadyGranted])
	func failedCreditsSetupKeepsOpenRouterForToolTurns(outcome: FixtureCreditsOutcome)
		async throws
	{
		let model = try await open(.openRouterNeedsCredits, credits: outcome)
		let fixture = try #require(model.services.fixture)
		let previous = model.status.access
		let account = try fixture.secrets.creditsAccount()
		model.open(.settings)
		model.open(.accessMethod)
		await model.chooseAccess(.useCredits)
		try #require(model.accessNotice != nil)
		#expect(model.status.access == previous)
		#expect(model.selectedAccessMethod == .openRouterAccount)
		#expect(try fixture.secrets.creditsAccount() == account)
		#expect(
			try fixture.secrets.openRouterAccountKey(at: .legacy)
				== FirstWeekFixture.openRouterKey)
		model.navigation.removeAll()
		try await harness.proveToolTurn(
			model, method: .openRouterAccount, model: FirstWeekFixture.openRouterModel)
	}

	@Test(arguments: [FixtureCreditsOutcome.zero, .unavailable])
	func creditsResultsDiscardStaleSuccess(outcome: FixtureCreditsOutcome) async throws {
		let model = try await open(.credits)
		await model.loadCredits()
		try #require(model.balance?.units == 200)
		let fixture = try #require(model.services.fixture)
		FirstWeekFixture.install(outcome, on: fixture.credits)
		await model.loadCredits()
		#expect(model.balance?.units == (outcome == .zero ? 0 : nil))
		#expect(
			model.creditsNotice?.key
				== (outcome == .zero
					? Catalog.creditsErrorExhausted : Catalog.creditsErrorUnavailable))
		#expect(model.selectedAccessMethod == .credits)
		if outcome == .zero {
			#expect(
				model.creditsNotice?.sentence(in: model.displayLocale)
					== "You're out of Credits. You can switch to your OpenRouter account.")
		}
	}

	private func open(
		_ method: FixtureAccessMethod, credits: FixtureCreditsOutcome = .ready
	) async throws -> ShellModel {
		var launch = harness.launch
		launch.accessMethod = method
		launch.creditsOutcome = credits
		let services = try fixtureServices(launch, defaults: harness.defaults)
		let model = await harness.model(services)
		model.continueNotice()
		model.connectKey = "fixture"
		await model.connect()
		try #require(model.didConnect)
		await model.agreeAndStartChatting()
		try await harness.observed(model)
		return model
	}
}
