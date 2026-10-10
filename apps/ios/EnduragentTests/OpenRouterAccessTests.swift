import EnduragentCoach
import EnduragentCoachFixtures
import Testing

@testable import Enduragent

@MainActor
@Suite(.serialized, FixtureTestScope())
struct OpenRouterAccessTests {
	private let harness = FixtureLaunchTests()

	@Test(arguments: [
		(false, FixtureAccessMethod.credits, FixtureSignInOutcome.success),
		(false, .openRouter, .cancel),
		(true, .openRouter, .success),
		(true, .credits, .cancel),
	])
	func successAndCancelFromEachScreenReachTheNextToolTurn(
		settings: Bool, previous: FixtureAccessMethod, outcome: FixtureSignInOutcome
	) async throws {
		var launch = harness.launch
		launch.accessMethod = previous
		launch.signInOutcome = outcome
		let model = await harness.model(
			try fixtureServices(launch, defaults: harness.defaults, language: .en))
		await model.appear()
		model.continueNotice()
		model.connectKey = "fixture"
		await model.connect()
		try await model.waitForStatus {
			if case .connected = $0.training { return true }
			return false
		}
		model.continueConnect()
		await model.loadStarter()
		if settings {
			await model.agreeAndStartChatting()
			try await harness.observed(model)
			model.open(.settings)
			model.open(.accessMethod)
		} else {
			#expect(model.route == .onboarding(.starter))
		}
		let fixture = try #require(model.services.fixture)
		let selection = try fixture.secrets.accessSelection()
		let priorMark = model.selectedAccessMethod
		await model.chooseAccess(.signInToOpenRouter)
		#expect(await fixture.openRouterAuthorizer.requests.count == 1)
		let expectedMethod: AccessMethod
		let expectedKey: String
		if outcome == .success {
			try await model.waitForStatus { $0.access.savedMethod == .openRouterAccount }
			#expect(model.selectedAccessMethod == .openRouterAccount)
			#expect(try fixture.secrets.accessSelection() != selection)
			expectedMethod = .openRouterAccount
			expectedKey = "fixture-signed-in-openrouter-key"
		} else {
			#expect(model.selectedAccessMethod == priorMark)
			#expect(try fixture.secrets.accessSelection() == selection)
			#expect(model.accessSettings.notice?.key == Catalog.accessSignInCancelled)
			expectedMethod = priorMark
			expectedKey =
				previous == .openRouter
				? FirstWeekFixture.openRouterKey : FirstWeekFixture.creditsKey
		}
		let expectedModel = try #require(model.status.access.model)
		#expect(
			expectedModel
				== (previous == .openRouter
					? FirstWeekFixture.openRouterModel : AppServices.builtInModel))
		await model.agreeAndStartChatting()
		try await harness.observed(model)
		model.navigation.removeAll()
		try await harness.proveToolTurn(
			model, method: expectedMethod, key: expectedKey, model: expectedModel)
	}

	@Test func concurrentRecoveryStartsOneSignIn() async throws {
		var launch = harness.launch
		launch.accessMethod = .openRouter
		launch.signInOutcome = .held
		let model = await harness.model(
			try fixtureServices(launch, defaults: harness.defaults, language: .en))
		await model.appear()
		model.continueNotice()
		model.connectKey = "fixture"
		await model.connect()
		try await model.waitForStatus {
			if case .connected = $0.training { return true }
			return false
		}
		model.continueConnect()
		await model.agreeAndStartChatting()
		try await harness.observed(model)
		let fixture = try #require(model.services.fixture)
		try await OpenRouterRejectionFixture.rejectTwoRequests(
			coach: model.services.coach, transport: fixture.transport)
		_ = try await harness.settledTurn(model, at: 0)
		try await model.waitForStatus { $0.access.attention == .rejectedKey }
		#expect(model.status.access.notice?.actions == [.signInToOpenRouter])
		let first = try #require(model.chat?.turns.first)
		let previous = try fixture.secrets.accessSelection()
		let one = Task { await model.perform(.signInToOpenRouter) }
		let two = Task { await model.perform(.signInToOpenRouter) }
		defer {
			one.cancel()
			two.cancel()
		}
		try await until { await !fixture.openRouterAuthorizer.requests.isEmpty }
		try #require(await fixture.openRouterAuthorizer.requests.count == 1)
		await fixture.openRouterAuthorizer.complete(.success(.init(code: "fixture-code")), at: 0)
		await one.value
		await two.value
		try await model.waitForStatus { $0.access.attention == nil }
		#expect(await fixture.openRouterAuthorizer.requests.count == 1)
		#expect(try fixture.secrets.accessSelection() != previous)
		#expect(model.selectedAccessMethod == .openRouterAccount)
		#expect(model.navigation.isEmpty)
		#expect(model.chat?.turns.first == first)
		try await harness.proveToolTurn(
			model, method: .openRouterAccount, key: "fixture-signed-in-openrouter-key",
			model: FirstWeekFixture.openRouterModel)
	}

	@Test(arguments: [false, true])
	func missingAndForbiddenKeysOfferOnlyTheirOwnRecovery(forbidden: Bool) async throws {
		var launch = harness.launch
		launch.accessMethod = forbidden ? .openRouter : .missingOpenRouter
		let model = await harness.model(
			try fixtureServices(launch, defaults: harness.defaults, language: .en))
		await model.agreeAndStartChatting()
		try await harness.observed(model)
		model.draft.text = forbidden ? "fixture:fail 403" : "Missing connection"
		await model.send()
		let turn = try await harness.settledTurn(model, at: 0)
		guard case .failed(let failure) = turn.state else {
			Issue.record("Expected an access notice")
			return
		}
		#expect(model.status.access.attention == (forbidden ? nil : .signInNeeded))
		#expect(failure.notice?.actions == (forbidden ? [] : [.chooseAccessMethod]))
		if forbidden {
			#expect(
				failure.notice?.sentence(in: model.displayLocale)
					== "OpenRouter blocked this request. Try a different model or message.")
		} else {
			await model.perform(.chooseAccessMethod)
			#expect(model.navigation == [.accessMethod])
		}
		await model.perform(.signInToOpenRouter)
		let fixture = try #require(model.services.fixture)
		#expect(await fixture.openRouterAuthorizer.requests.isEmpty)
		#expect(fixture.transport.requestCount == (forbidden ? 1 : 0))
	}
}
