import EnduragentCoach
import EnduragentCoachFixtures
import Testing

@testable import Enduragent

@MainActor
@Suite(.serialized, FixtureTestScope())
struct AccessOnboardingTests {
	private let harness = FixtureLaunchTests()

	@Test func starterCreditsThenStartChattingReopensForToolTurn() async throws {
		do {
			let model = try await open(.creditsNeedsSetup)
			let fixture = try #require(model.services.fixture)
			try #require(try await model.services.coach.creditsIdentity().hasCreditsKey == false)
			await model.loadStarter()
			#expect(model.starterResolved)
			#expect(model.starterLine == "200 credits")
			#expect(try fixture.secrets.creditsAccount()?.key == FirstWeekFixture.creditsKey)
			try await model.waitForStatus { $0.access.availability == .ready }
			await model.loadStarter()
			#expect(fixture.credits.calls == [.grant])
			await model.agreeAndStartChatting()
			try await harness.observed(model)
		}
		let reopened = try await harness.reopen(language: .en)
		#expect(reopened.status.access.availability == .ready)
		try await harness.proveToolTurn(reopened, method: .credits, model: AppServices.builtInModel)
	}

	@Test func failedStarterStillStartsChattingWithoutCredits() async throws {
		let model = try await open(.creditsNeedsSetup)
		let fixture = try #require(model.services.fixture)
		let backing = try #require(fixture.secretBacking)
		backing.failNextWrite = true
		await model.loadStarter()
		#expect(model.starterResolved)
		#expect(model.starterLine == model.phrasebook.say(Catalog.accessErrorStorageUnavailable))
		#expect(try await model.services.coach.creditsIdentity().hasCreditsKey == false)
		await model.agreeAndStartChatting()
		try await harness.observed(model)
		#expect(model.route == .chat)
		#expect(model.status.access.availability == .needsSetup)
	}

	private func open(_ method: FixtureAccessMethod) async throws -> ShellModel {
		var launch = harness.launch
		launch.accessMethod = method
		let services = try fixtureServices(launch, defaults: harness.defaults, language: .en)
		let model = await harness.model(services)
		await model.appear()
		model.continueNotice()
		model.connectKey = "fixture"
		await model.connect()
		try await model.waitForStatus {
			if case .connected = $0.training { return true }
			return false
		}
		model.continueConnect()
		try #require(model.route == .onboarding(.starter))
		return model
	}
}
