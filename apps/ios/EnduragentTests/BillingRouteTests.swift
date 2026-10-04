import EnduragentCoach
import EnduragentCoachFixtures
import Synchronization
import Testing

@testable import Enduragent

@MainActor
@Suite(.serialized, FixtureTestScope())
struct BillingRouteTests {
	private let harness = FixtureLaunchTests()

	@Test(arguments: [FixtureAccessMethod.credits, .openRouter])
	func destinationsNeverClaimOrSwitchAccess(method: FixtureAccessMethod) async throws {
		var launch = harness.launch
		launch.accessMethod = method
		let model = await harness.model(
			try fixtureServices(launch, defaults: harness.defaults, language: .en))
		let fixture = try #require(model.services.fixture)
		let selection = try fixture.secrets.accessSelection()
		let account = try fixture.secrets.creditsAccount()
		try #require(
			try fixture.secrets.openRouterAccountKey(at: .legacy) == FirstWeekFixture.openRouterKey)
		await model.appear()
		model.continueNotice()
		model.skipConnect()
		await model.loadStarter()
		#expect(model.route == .onboarding(.starter))
		#expect(fixture.credits.calls == [.grant])
		try assertUnchanged(model, selection: selection, account: account)
		#expect(fixture.transport.requestCount == 0)
		await model.agreeAndStartChatting()
		try await harness.observed(model)
		model.draft.text = TutorialCopy.weekQuestion
		await model.send()
		let answered = try await harness.settledTurn(model, at: 0)
		try #require(replyText(answered.state) == FirstWeekFixture.weekSummary)
		let modelRequests = fixture.transport.requestCount
		let saved = try #require(model.chat)
		for destination in [ShellDestination.settings, .accessMethod, .credits] {
			model.open(destination)
			if destination == .credits { await model.loadCredits() }
			try assertUnchanged(model, selection: selection, account: account)
			#expect(model.chat?.turns == saved.turns)
		}
		for action in [
			RecoveryAction.buyCredits, .restoreCredits, .chooseAccessMethod,
		] {
			model.navigation.removeAll()
			await model.perform(action)
			if action == .buyCredits || action == .restoreCredits { await model.loadCredits() }
			#expect(
				model.navigation == [
					action == .buyCredits || action == .restoreCredits ? .credits : .accessMethod
				])
			try assertUnchanged(model, selection: selection, account: account)
			#expect(model.chat?.turns == saved.turns)
		}
		#expect(fixture.transport.requestCount == modelRequests)
	}

	@Test(arguments: [FixtureAccessMethod.credits, .openRouter])
	func conversationFailuresKeepIdentityAndExposeRealCredits(method: FixtureAccessMethod)
		async throws
	{
		var launch = harness.launch
		launch.accessMethod = method
		let model = await harness.model(
			try fixtureServices(launch, defaults: harness.defaults, language: .en))
		let fixture = try #require(model.services.fixture)
		let selection = try fixture.secrets.accessSelection()
		let account = try #require(try fixture.secrets.creditsAccount())
		let requests = Mutex<[ScriptedRequest]>([])
		let respond = fixture.transport.respond
		fixture.transport.respond = { request in
			requests.withLock { $0.append(request) }
			return respond(request)
		}
		await model.agreeAndStartChatting()
		try await harness.observed(model)
		await model.loadCredits()
		try #require(model.balance?.units == 200)
		model.draft.text = "fixture:teach"
		await model.send()
		let remembered = try await harness.settledTurn(model, at: 0)
		#expect(replyText(remembered.state) == FirstWeekFixture.rememberReply)
		model.draft.text = method == .credits ? "fixture:fail 402" : "fixture:fail 401"
		await model.send()
		let failed = try await harness.settledTurn(model, at: 1)
		guard case .failed(let failure) = failed.state else {
			Issue.record("Expected the selected method to fail")
			return
		}
		let action: RecoveryAction = method == .credits ? .buyCredits : .signInToOpenRouter
		#expect(failure.notice.action == (method == .credits ? action : nil))
		if method == .openRouter {
			try await model.waitForStatus { $0.access.attention == .rejectedKey }
			#expect(model.status.access.notice?.action == action)
		}
		#expect(
			failure.notice.key
				== (method == .credits
					? Catalog.creditsErrorExhausted : Catalog.coachErrorReauth))
		let saved = try #require(model.chat)
		await model.perform(action)
		if method == .credits {
			await model.loadCredits()
			#expect(model.balance?.units == 0)
			#expect(
				model.creditsNotice?.sentence(in: model.displayLocale)
					== "You're out of Credits. You can switch to your OpenRouter account.")
			#expect(model.catalog?.purchasesEnabled == false)
			model.open(.accessMethod)
		} else {
			await model.loadCredits()
			#expect(model.balance?.units == 200)
		}
		try assertUnchanged(model, selection: selection, account: account)
		#expect(model.chat?.turns == saved.turns)
		let sent = requests.withLock { $0 }
		try #require(sent.count >= 3)
		#expect(
			sent.allSatisfy {
				$0.accessMethod == (method == .credits ? .credits : .openRouterAccount)
					&& $0.model
						== (method == .credits
							? AppServices.builtInModel : FirstWeekFixture.openRouterModel)
			})
	}

	private func assertUnchanged(
		_ model: ShellModel, selection: SavedAccessReference?, account: CreditsAccount?
	) throws {
		let fixture = try #require(model.services.fixture)
		#expect(try fixture.secrets.accessSelection() == selection)
		#expect(try fixture.secrets.creditsAccount() == account)
		#expect(
			try fixture.secrets.openRouterAccountKey(at: .legacy) == FirstWeekFixture.openRouterKey)
		#expect(
			fixture.credits.calls.allSatisfy { $0 == .grant || $0 == .catalog || $0 == .balance })
	}
}
