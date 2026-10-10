import EnduragentCoach
import EnduragentCoachFixtures
import Testing

@testable import Enduragent

@MainActor
@Suite(.serialized, FixtureTestScope())
struct AccessOnboardingTests {
	private let harness = FixtureLaunchTests()

	@Test func starterSetupThenCreditsChoiceReopensForToolTurn() async throws {
		do {
			let model = try await open(.creditsNeedsSetup)
			let fixture = try #require(model.services.fixture)
			let saved = try fixture.secrets.accessSelection()
			try #require(try await model.services.coach.creditsIdentity().hasCreditsKey == false)
			await model.loadStarter()
			#expect(model.starterResolved)
			#expect(model.starterLine == "200 credits")
			#expect(try fixture.secrets.creditsAccount()?.key == FirstWeekFixture.creditsKey)
			#expect(try fixture.secrets.accessSelection() == saved)
			await model.chooseAccess(.useCredits)
			try await model.waitForStatus { $0.access.savedMethod == .credits }
			#expect(model.status.access.availability == .ready)
			#expect(model.starterLine == "200 credits")
			#expect(fixture.credits.calls == [.grant])
			await model.loadStarter()
			#expect(fixture.credits.calls == [.grant])
			await model.agreeAndStartChatting()
			try await harness.observed(model)
			model.open(.settings)
			model.open(.accessMethod)
			#expect(model.selectedAccessMethod == .credits)
		}
		let reopened = try await harness.reopen(language: .en)
		#expect(reopened.selectedAccessMethod == .credits)
		#expect(reopened.status.access.availability == .ready)
		try await harness.proveToolTurn(reopened, method: .credits, model: AppServices.builtInModel)
	}

	@Test(arguments: ["credential-write", "selection-write"])
	func failedStarterAndChoicesKeepPreviousAccess(fault: String) async throws {
		let model = try await open(.openRouterNeedsCredits)
		let fixture = try #require(model.services.fixture)
		let backing = try #require(fixture.secretBacking)
		let previous = model.status.access
		let selection = try fixture.secrets.accessSelection()
		if fault == "credential-write" { backing.failNextWrite = true }
		await model.loadStarter()
		if fault == "selection-write" { try #require(model.starterLine == "200 credits") }
		backing.failNextWrite = true
		await model.chooseAccess(.useCredits)
		let expected =
			fault == "credential-write"
			? Catalog.accessErrorStorageUnavailable : Catalog.reviewSaveFailed
		#expect(model.starterResolved)
		#expect(model.starterLine == model.phrasebook.say(expected))
		#expect(model.starterLine != "200 credits")
		#expect(model.status.access.selection == previous.selection)
		#expect(model.status.access.savedMethod == previous.savedMethod)
		#expect(model.status.access.model == previous.model)
		#expect(model.status.access.availability == previous.availability)
		#expect(try fixture.secrets.accessSelection() == selection)
		if fault == "credential-write" {
			#expect(try await model.services.coach.creditsIdentity().hasCreditsKey == false)
		}
		await model.agreeAndStartChatting()
		try await harness.observed(model)
		model.open(.settings)
		model.open(.accessMethod)
		#expect(model.selectedAccessMethod == (previous.savedMethod ?? .credits))
		#expect(model.accessSettings.notice == nil)
		#expect(model.accessNotice == nil)
		model.navigation.removeAll()
		try await harness.proveToolTurn(
			model, method: previous.savedMethod ?? .credits,
			model: try #require(previous.model))
		#expect(fixture.credits.calls.allSatisfy { $0 == .grant || $0 == .balance })
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
