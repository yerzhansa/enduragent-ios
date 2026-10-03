import EnduragentCoach
import EnduragentCoachFixtures
import Synchronization
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
		let reopened = try await reopen()
		#expect(reopened.selectedAccessMethod == .credits)
		#expect(reopened.status.access.availability == .ready)
		try await proveToolTurn(reopened, method: .credits, model: AppServices.builtInModel)
	}

	@Test(arguments: [
		"leave", "sign-in", "selection-write", "provisioning", "credential-write",
		"already-granted",
	])
	func leavingAndFailedChoicesKeepOpenRouterForToolTurnsAfterRelaunch(fault: String) async throws
	{
		let previous: AccessStatus
		let saved: ChatSnapshot
		do {
			let needsSetup = ["provisioning", "credential-write", "already-granted"].contains(fault)
			let outcome: FixtureCreditsOutcome =
				fault == "provisioning"
				? .provisioningFailed
				: fault == "already-granted" ? .alreadyGranted : .ready
			let model = try await open(
				needsSetup ? .openRouterNeedsCredits : .openRouter, credits: outcome)
			let fixture = try #require(model.services.fixture)
			previous = model.status.access
			let account = try fixture.secrets.creditsAccount()
			model.open(.settings)
			model.open(.accessMethod)
			switch fault {
			case "leave": break
			case "sign-in": await model.chooseAccess(.signInToOpenRouter)
			case "selection-write", "credential-write":
				let backing = try #require(fixture.secretBacking)
				backing.failNextWrite = true
				await model.chooseAccess(.useCredits)
			default: await model.chooseAccess(.useCredits)
			}
			if fault != "leave" { try #require(model.accessNotice != nil) }
			if fault == "selection-write" {
				#expect(
					model.accessNotice?.sentence(in: model.displayLocale)
						== "Couldn't save your choice on this iPhone, so nothing was changed. Try again."
				)
			}
			if fault == "sign-in" {
				#expect(await fixture.openRouterAuthorizer.requests.count == 1)
				#expect(model.accessNotice?.key == Catalog.accessSignInCancelled)
			}
			#expect(model.status.access == previous)
			#expect(model.selectedAccessMethod == .openRouterAccount)
			#expect(try fixture.secrets.creditsAccount() == account)
			#expect(
				try fixture.secrets.openRouterAccountKey(at: .legacy)
					== FirstWeekFixture.openRouterKey)
			model.navigation.removeAll()
			try await proveToolTurn(
				model, method: .openRouterAccount, model: FirstWeekFixture.openRouterModel)
			saved = try #require(model.chat)
		}
		let reopened = try await reopen()
		#expect(reopened.status.access == previous)
		#expect(reopened.chat?.turns == saved.turns)
		try await proveToolTurn(
			reopened, method: .openRouterAccount, model: FirstWeekFixture.openRouterModel)
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

	private func reopen() async throws -> ShellModel {
		let (services, defaults) = try await harness.relaunch(.keep)
		let model = await fixtureModel(
			environment: AppEnvironment(services: services, defaults: defaults))
		try await harness.observed(model)
		return model
	}

	private func proveToolTurn(
		_ shell: ShellModel, method: AccessMethod, model: ModelID
	) async throws {
		let transport = try #require(shell.services.fixtureTransport)
		let previous = transport.respond
		let requests = Mutex<[ScriptedRequest]>([])
		transport.respond = { request in
			requests.withLock { $0.append(request) }
			return previous(request)
		}
		let turnIndex = try #require(shell.chat).turns.count
		shell.draft.text = FirstWeekFixture.trainingDataDirective
		await shell.send()
		let turn = try await harness.settledTurn(shell, at: turnIndex)
		try #require(replyText(turn.state) != nil)
		let chatRequests = requests.withLock { $0.filter { $0.purpose == .chat } }
		try #require(chatRequests.count >= 2)
		#expect(chatRequests.contains { !$0.toolResults.isEmpty })
		#expect(chatRequests.allSatisfy { $0.accessMethod == method && $0.model == model })
	}
}
