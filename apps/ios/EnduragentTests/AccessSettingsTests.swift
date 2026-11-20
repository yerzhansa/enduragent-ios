import EnduragentCoach
import EnduragentCoachFixtures
import Testing

@testable import Enduragent

@MainActor
@Suite(.serialized, FixtureTestScope())
struct AccessSettingsTests {
	private let harness = FixtureLaunchTests()

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
		if outcome == .zero {
			#expect(
				model.creditsNotice?.sentence(in: model.displayLocale)
					== "You're out of Credits. You can buy Credits.")
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
