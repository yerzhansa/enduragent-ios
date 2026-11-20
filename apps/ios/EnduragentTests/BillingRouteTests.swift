import EnduragentCoach
import EnduragentCoachFixtures
import Foundation
import Synchronization
import Testing

@testable import Enduragent

@MainActor
@Suite(.serialized, FixtureTestScope())
struct BillingRouteTests {
	private let harness = FixtureLaunchTests()

	@Test(arguments: [FixtureAccessMethod.credits, .build9OpenRouter])
	func destinationsNeverClaimOrChangeTheAccount(method: FixtureAccessMethod) async throws {
		var launch = harness.launch
		launch.accessMethod = method
		let model = await harness.model(
			try fixtureServices(launch, defaults: harness.defaults, language: .en))
		let fixture = try #require(model.services.fixture)
		let saved = try keychainItems(fixture)
		await model.appear()
		model.continueNotice()
		model.skipConnect()
		await model.loadStarter()
		#expect(model.route == .onboarding(.starter))
		#expect(fixture.credits.calls == [.grant])
		try assertUnchanged(model, saved)
		#expect(fixture.transport.requestCount == 0)
		await model.agreeAndStartChatting()
		try await harness.observed(model)
		model.draft.text = TutorialCopy.weekQuestion
		await model.send()
		let answered = try await harness.settledTurn(model, at: 0)
		try #require(replyText(answered.state) == FirstWeekFixture.weekSummary)
		let modelRequests = fixture.transport.requestCount
		let chat = try #require(model.chat)
		for destination in [ShellDestination.settings, .credits] {
			model.open(destination)
			if destination == .credits { await model.loadCredits() }
			try assertUnchanged(model, saved)
			#expect(model.chat?.turns == chat.turns)
		}
		model.navigation.removeAll()
		await model.perform(.buyCredits)
		#expect(model.navigation == [.credits])
		try assertUnchanged(model, saved)
		#expect(model.chat?.turns == chat.turns)
		#expect(fixture.transport.requestCount == modelRequests)
	}

	@Test(arguments: [FixtureAccessMethod.credits, .build9OpenRouter])
	func outOfCreditsKeepsTheConversationAndLeadsToBuyCredits(method: FixtureAccessMethod)
		async throws
	{
		var launch = harness.launch
		launch.accessMethod = method
		let model = await harness.model(
			try fixtureServices(launch, defaults: harness.defaults, language: .en))
		let fixture = try #require(model.services.fixture)
		let saved = try keychainItems(fixture)
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
		model.draft.text = "fixture:fail 402"
		await model.send()
		let failed = try await harness.settledTurn(model, at: 1)
		guard case .failed(let failure) = failed.state else {
			Issue.record("Expected the Credits request to fail")
			return
		}
		#expect(failure.notice?.key == Catalog.creditsErrorExhausted)
		#expect(failure.notice?.actions == [.buyCredits])
		let chat = try #require(model.chat)
		await model.perform(.buyCredits)
		#expect(model.navigation == [.credits])
		await model.loadCredits()
		#expect(model.balance?.units == 0)
		#expect(
			model.creditsNotice?.sentence(in: model.displayLocale)
				== "You're out of Credits. You can buy Credits.")
		#expect(model.creditOffers?.count == 3)
		try assertUnchanged(model, saved)
		#expect(model.chat?.turns == chat.turns)
		let sent = requests.withLock { $0 }
		try #require(sent.count >= 3)
		#expect(
			sent.allSatisfy {
				$0.accessMethod == .credits && $0.model == AppServices.builtInModel
					&& $0.credential == FirstWeekFixture.creditsKey
			})
	}

	private struct KeychainItems: Equatable {
		let account: CreditsAccount?
		let build9: [Data?]
	}

	private func keychainItems(_ fixture: FixtureServices) throws -> KeychainItems {
		let backing = try #require(fixture.secretBacking)
		return KeychainItems(
			account: try fixture.secrets.creditsAccount(),
			build9: try ["openRouterAccountKey", CredentialSlot.accessSelection.rawValue].map {
				try backing.copy(account: $0)
			})
	}

	private func assertUnchanged(_ model: ShellModel, _ saved: KeychainItems) throws {
		let fixture = try #require(model.services.fixture)
		#expect(try keychainItems(fixture) == saved)
		#expect(
			fixture.credits.calls.allSatisfy { $0 == .grant || $0 == .catalog || $0 == .balance })
	}
}
