import EnduragentCoach
import EnduragentCoachFixtures
import Synchronization
import Testing

@testable import Enduragent

@MainActor
@Suite(.serialized, FixtureTestScope())
struct OpenRouterAccessTests {
	private let harness = FixtureLaunchTests()

	@Test(arguments: [
		(false, FixtureAccessMethod.credits, FixtureSignInOutcome.success),
		(false, .credits, .cancel),
		(false, .openRouter, .success),
		(false, .openRouter, .cancel),
		(true, .credits, .success),
		(true, .credits, .cancel),
		(true, .openRouter, .success),
		(true, .openRouter, .cancel),
	])
	func successAndCancelFromEachScreenPersistForToolTurn(
		settings: Bool, previous: FixtureAccessMethod, outcome: FixtureSignInOutcome
	) async throws {
		let saved: ChatSnapshot
		let expectedModel: ModelID
		let expectedMethod: AccessMethod
		let expectedKey: String
		do {
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
			expectedModel = try #require(model.status.access.model)
			#expect(
				expectedModel
					== (previous == .openRouter
						? FirstWeekFixture.openRouterModel : AppServices.builtInModel))
			await model.agreeAndStartChatting()
			try await harness.observed(model)
			model.navigation.removeAll()
			try await proveToolTurn(
				model, method: expectedMethod, key: expectedKey, model: expectedModel)
			saved = try #require(model.chat)
		}
		let (services, defaults) = try await harness.relaunch(.keep, language: .en)
		let reopened = await fixtureModel(
			environment: AppEnvironment(services: services, defaults: defaults))
		try await harness.observed(reopened)
		#expect(reopened.selectedAccessMethod == expectedMethod)
		#expect(reopened.status.access.model == expectedModel)
		#expect(reopened.chat?.turns == saved.turns)
		try await proveToolTurn(
			reopened, method: expectedMethod, key: expectedKey, model: expectedModel)
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
		let deadline = ContinuousClock.now + TestWaitLimit.hangGuard.duration
		while await fixture.openRouterAuthorizer.requests.isEmpty, ContinuousClock.now < deadline {
			try await Task.sleep(for: .milliseconds(20))
		}
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
		try await proveToolTurn(
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
		#expect(failure.notice?.actions == (forbidden ? nil : [.chooseAccessMethod]))
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

	private func proveToolTurn(
		_ shell: ShellModel, method: AccessMethod, key: String, model: ModelID
	) async throws {
		let fixture = try #require(shell.services.fixture)
		let response = fixture.transport.respond
		let requests = Mutex<[ScriptedRequest]>([])
		fixture.transport.respond = { request in
			requests.withLock { $0.append(request) }
			return response(request)
		}
		let index = try #require(shell.chat).turns.count
		shell.draft.text = FirstWeekFixture.trainingDataDirective
		await shell.send()
		let turn = try await harness.settledTurn(shell, at: index)
		#expect(replyText(turn.state) == "I can read Ada Kovač's training profile and calendar.")
		let sent = requests.withLock { $0.filter { $0.purpose == .chat } }
		try #require(sent.count >= 2)
		#expect(sent.contains { !$0.toolResults.isEmpty })
		#expect(
			sent.allSatisfy {
				$0.accessMethod == method && $0.credential == key && $0.model == model
			})
	}
}
