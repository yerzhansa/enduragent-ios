import EnduragentCoach
import EnduragentCoachFixtures
import Testing

@testable import Enduragent

@MainActor
@Suite(.serialized, FixtureTestScope())
struct AccessOnboardingTests {
	private let harness = FixtureLaunchTests()

	@Test(arguments: [FixtureAccessMethod.creditsNeedsSetup, .openRouterNeedsCredits])
	func starterSetupThenCreditsChoiceReopensForToolTurn(method: FixtureAccessMethod) async throws {
		do {
			let model = try await open(method)
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

	@Test(arguments: [
		"unavailable", "provisioning", "credential-write", "already-granted", "selection-write",
		"sign-in-openrouter", "sign-in-credits",
	])
	func failedStarterAndChoicesKeepPreviousAccess(fault: String) async throws {
		let previous: AccessStatus
		let saved: ChatSnapshot
		do {
			let method: FixtureAccessMethod =
				fault == "sign-in-credits"
				? .credits
				: ["unavailable", "sign-in-openrouter"].contains(fault)
					? .openRouter : .openRouterNeedsCredits
			let outcome: FixtureCreditsOutcome =
				fault == "provisioning"
				? .provisioningFailed
				: fault == "already-granted" ? .alreadyGranted : .ready
			let model = try await open(method, credits: outcome)
			let fixture = try #require(model.services.fixture)
			let backing = try #require(fixture.secretBacking)
			previous = model.status.access
			let selection = try fixture.secrets.accessSelection()
			if fault == "unavailable" {
				fixture.credits.grantResult = .success(.alreadyGranted)
				fixture.credits.balanceResult = .failure(.unavailable)
			}
			if fault == "credential-write" { backing.failNextWrite = true }
			await model.loadStarter()
			switch fault {
			case "selection-write":
				try #require(model.starterLine == "200 credits")
				backing.failNextWrite = true
				await model.chooseAccess(.useCredits)
			case "sign-in-openrouter", "sign-in-credits":
				await model.chooseAccess(.signInToOpenRouter)
			case "credential-write":
				backing.failNextWrite = true
				await model.chooseAccess(.useCredits)
			case "provisioning", "already-granted":
				await model.chooseAccess(.useCredits)
			default: break
			}
			if fault.hasPrefix("sign-in") {
				#expect(await fixture.openRouterAuthorizer.requests.count == 1)
			}
			let expected: CatalogKey =
				switch fault {
				case "credential-write": Catalog.accessErrorStorageUnavailable
				case "already-granted": Catalog.onboardingStarterAlreadyGranted
				case "selection-write": Catalog.reviewSaveFailed
				case "sign-in-openrouter", "sign-in-credits": Catalog.accessSignInCancelled
				default: Catalog.creditsErrorUnavailable
				}
			#expect(model.starterResolved)
			#expect(model.starterLine == model.phrasebook.say(expected))
			#expect(model.starterLine != "200 credits")
			#expect(model.status.access.selection == previous.selection)
			#expect(model.status.access.savedMethod == previous.savedMethod)
			#expect(model.status.access.model == previous.model)
			#expect(model.status.access.availability == previous.availability)
			#expect(try fixture.secrets.accessSelection() == selection)
			if method == .openRouterNeedsCredits && fault != "selection-write" {
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
			saved = try #require(model.chat)
			#expect(fixture.credits.calls.allSatisfy { $0 == .grant || $0 == .balance })
		}
		let reopened = try await harness.reopen(language: .en)
		#expect(reopened.status.access.selection == previous.selection)
		#expect(reopened.status.access.savedMethod == previous.savedMethod)
		#expect(reopened.status.access.model == previous.model)
		#expect(reopened.status.access.availability == previous.availability)
		#expect(reopened.chat?.turns == saved.turns)
		try await harness.proveToolTurn(
			reopened, method: previous.savedMethod ?? .credits,
			model: try #require(previous.model))
	}

	private func open(
		_ method: FixtureAccessMethod, credits: FixtureCreditsOutcome = .ready
	) async throws -> ShellModel {
		var launch = harness.launch
		launch.accessMethod = method
		launch.creditsOutcome = credits
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
