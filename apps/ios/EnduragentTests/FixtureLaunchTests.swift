import EnduragentCoach
import EnduragentCoachFixtures
import Foundation
import Security
import Testing

@testable import Enduragent

@MainActor
@Suite(.serialized, FixtureTestScope())
final class FixtureLaunchTests {
	var fixture: AppTestFixture { AppTestFixture.active }
	var launch: FixtureLaunch { fixture.launch }
	var defaults: UserDefaults { fixture.defaults }
	let language = Language.uiTag(systemLanguages: Locale.preferredLanguages)

	func services(keychain: FixtureKeychainPolicy = .unlocked) throws -> AppServices {
		var launch = launch
		launch.keychain = keychain
		return try fixtureServices(launch, defaults: defaults)
	}

	func relaunch(
		_ store: FixtureStorePolicy, keychain: FixtureKeychainPolicy = .unlocked,
		recovery: FixtureRecoveryPolicy = .readable, clock: String? = nil,
		language: LanguageTag? = nil
	) async throws -> (AppServices, UserDefaults) {
		var launch = launch
		launch.store = store
		launch.keychain = keychain
		launch.recovery = recovery
		launch.clock = clock ?? launch.clock
		await fixture.releaseOwners()
		try await fixture.folder.waitUntilUnused()
		let defaults = try launch.prepare()
		return (
			try fixtureServices(launch, defaults: defaults, language: language ?? self.language),
			defaults
		)
	}

	func model(_ services: AppServices) async -> ShellModel {
		await fixtureModel(environment: environment(services))
	}

	func environment(_ services: AppServices) -> AppEnvironment {
		AppEnvironment(services: services, defaults: defaults)
	}

	func until(
		within limit: TestWaitLimit = .hangGuard, _ condition: () -> Bool
	) async throws {
		let deadline = ContinuousClock.now + limit.duration
		while !condition(), ContinuousClock.now < deadline {
			try await Task.sleep(for: .milliseconds(20))
		}
		try #require(condition())
	}

	func settledTurn(
		_ model: ShellModel, after previous: TurnState? = nil,
		within limit: TestWaitLimit = .hangGuard
	) async throws -> TurnView {
		let deadline = ContinuousClock.now + limit.duration
		while ContinuousClock.now < deadline {
			if let turn = model.chat?.turns.last, turn.state.isSettled, turn.state != previous {
				return turn
			}
			try await Task.sleep(for: .milliseconds(20))
		}
		return try #require(model.chat?.turns.last(where: { $0.state.isSettled }))
	}

	func settledTurn(_ model: ShellModel, at index: Int) async throws -> TurnView {
		let deadline = ContinuousClock.now + TestWaitLimit.hangGuard.duration
		while ContinuousClock.now < deadline {
			if let turns = model.chat?.turns, turns.indices.contains(index),
				turns[index].state.isSettled
			{
				return turns[index]
			}
			try await Task.sleep(for: .milliseconds(20))
		}
		let turns = try #require(model.chat?.turns)
		try #require(turns.indices.contains(index))
		return turns[index]
	}

	func observed(_ model: ShellModel) async throws {
		await model.appear()
		let deadline = ContinuousClock.now + TestWaitLimit.hangGuard.duration
		while model.chat == nil, ContinuousClock.now < deadline {
			try await Task.sleep(for: .milliseconds(20))
		}
		try #require(model.chat != nil)
	}

	func firstTurn(_ model: ShellModel) async throws -> TurnView {
		let deadline = ContinuousClock.now + TestWaitLimit.hangGuard.duration
		while model.chat?.turns.isEmpty ?? true, ContinuousClock.now < deadline {
			try await Task.sleep(for: .milliseconds(20))
		}
		return try #require(model.chat?.turns.first)
	}

	func firstSnapshot(_ services: AppServices, chat: ChatID) async -> ChatSnapshot? {
		var iterator = await services.coach.observe(chat).makeAsyncIterator()
		return await iterator.next()
	}

	@Test func fixtureArgumentBuildsCoachFromFakes() async throws {
		let services = try services()
		#expect(services.fixture != nil)
		#expect(
			try await #require(services.fixture).intervals.fetchAthlete().name
				== "Ada Kovač")
		#expect(try await services.coach.observedStatus().training == .unconnected)
		let model = await model(services)
		#expect(model.route == .onboarding(.notice))
		#expect(model.chat == nil)
	}

	@Test func unknownFixtureNameThrows() throws {
		var unknown = launch
		unknown.name = "second-week"
		#expect(throws: FixtureLaunchError.self) {
			try fixtureServices(unknown, defaults: defaults)
		}
	}

	@Test func coalescingArgumentSetsTheWindowTheCoachHolds() async throws {
		let suite = "enduragent.fixture.arguments.test"
		let arguments = try #require(UserDefaults(suiteName: suite))
		defer { arguments.removePersistentDomain(forName: suite) }
		arguments.set(FixtureLaunch.firstWeekName, forKey: FixtureLaunch.nameArgumentKey)
		arguments.set("soon", forKey: FixtureLaunch.coalescingArgumentKey)
		#expect(throws: FixtureLaunchError.self) { try FixtureLaunch.fromArguments(arguments) }
		arguments.set("2000", forKey: FixtureLaunch.coalescingArgumentKey)
		let parsed = try #require(try FixtureLaunch.fromArguments(arguments))
		#expect(parsed.coalescing == CoalescingPolicy(window: .seconds(2)))
		var widened = launch
		widened.coalescing = parsed.coalescing
		let services = try fixtureServices(widened, defaults: defaults)
		let model = await model(services)
		await model.agreeAndStartChatting()
		model.draft.text = TutorialCopy.weekQuestion
		await model.send()
		let turn = try await firstTurn(model)
		#expect(
			turn.state == .accepted(.collecting(until: services.clock.now.addingTimeInterval(2))))
		let settled = try await settledTurn(model)
		#expect(replyText(settled.state)?.contains("Tuesday sweet spot") == true)
	}

	@Test func starterScreenResolvesOnlyAfterGrant() async throws {
		let model = await model(try services())
		#expect(model.starterResolved == false)
		await model.loadStarter()
		#expect(model.starterResolved)
		#expect(model.starterLine == "200 credits")
	}

	@Test func skippingConnectMovesToStarterWithoutAthlete() async throws {
		let model = await model(try services())
		model.continueNotice()
		model.connectKey = "abandoned-key"
		model.skipConnect()
		#expect(model.connectKey.isEmpty)
		#expect(model.route == .onboarding(.starter))
		#expect(model.connected == nil)
		#expect(model.athleteFirstName.isEmpty)
	}

	@Test func alreadyGrantedWithStoredKeyShowsBalance() async throws {
		let services = try services()
		let fixture = try #require(services.fixture)
		fixture.credits.grantResult = .success(.alreadyGranted)
		try fixture.secrets.storeCreditsAccount(
			CreditsAccount(
				appAccountToken: UUID(),
				key: "sk-or-test-0000"))
		let model = await model(services)
		await model.loadStarter()
		#expect(model.starterLine == "200 credits")
	}

	@Test func fixtureLaunchStaysOnNotice() async throws {
		let model = await model(try services())
		#expect(model.route == .onboarding(.notice))
	}

	@Test func coldStartAfterAV1ChatOpensTheOneConversation() async throws {
		defaults.set(true, forKey: ShellModel.onboardingCompletedKey)
		defaults.set("restored-chat", forKey: "enduragent.lastChatId")
		let model = await model(try services())
		await model.agreeAndStartChatting()
		try await observed(model)
		#expect(model.route == .chat)
		#expect(model.chat?.chat == .main)
		#expect(model.chat?.opening == .welcome)
	}

	@Test func fixtureAppServicesOpensALegacySecretsFile() async throws {
		let legacy =
			#"{"appAccountToken":"11111111-2222-4333-8444-555555555555","openRouterKey":"fixture-legacy-credits-key"}"#
		try Data(legacy.utf8).write(to: launch.directory.appending(path: "secrets.json"))
		defaults.set(true, forKey: ShellModel.onboardingCompletedKey)
		let (services, kept) = try await relaunch(.keep)
		let reopened = await fixtureModel(
			environment: AppEnvironment(services: services, defaults: kept))
		await reopened.agreeAndStartChatting()
		try await observed(reopened)
		#expect(reopened.route == .chat)
		#expect(reopened.chat?.chat == .main)
		#expect(try await services.coach.observedStatus().setup == .ready)
		let identity = try await services.coach.creditsIdentity()
		#expect(
			identity.appAccountToken
				== UUID(uuidString: "11111111-2222-4333-8444-555555555555"))
		#expect(identity.hasCreditsKey)
		#expect(try services.fixture?.secrets.creditsAccount()?.key == "fixture-legacy-credits-key")
	}

	@Test func coldStartRestoresTheTypedDraft() async throws {
		defaults.set(true, forKey: ShellModel.onboardingCompletedKey)
		let first = await model(try services())
		await first.agreeAndStartChatting()
		first.draft.text = "Is Thursday still on?"
		first.draftChanged(from: "")
		let second = await model(try services())
		try await observed(first)
		try await observed(second)
		#expect(second.draft == first.draft)
		#expect(second.draft.text == "Is Thursday still on?")
	}

	@Test func startChattingPersistsSessionForNextLaunch() async throws {
		let services = try services()
		let first = await model(services)
		await first.agreeAndStartChatting()
		#expect(first.route == .chat)
		let second = await model(services)
		try await observed(first)
		try await observed(second)
		#expect(second.route == .chat)
		#expect(second.chat?.chat == .main)
	}

	@Test func chooseAccessMethodKeepsTheConversation() async throws {
		let model = await model(try services())
		await model.agreeAndStartChatting()
		model.draft.text = TutorialCopy.weekQuestion
		await model.send()
		let settled = try await settledTurn(model)
		await model.perform(.chooseAccessMethod)
		#expect(model.navigation == [.accessMethod])
		model.navigation.removeAll()
		#expect(model.route == .chat)
		try await observed(model)
		#expect(model.chat?.turns.map(\.id) == [settled.id])
		#expect(model.chat?.opening == .continuing)
	}

	@Test func newConversationArchivesTheExchangeAndOpensOnTheWelcome() async throws {
		let model = await model(try services())
		await model.agreeAndStartChatting()
		model.draft.text = TutorialCopy.weekQuestion
		await model.send()
		let settled = try await settledTurn(model)
		await model.newConversation()
		let deadline = ContinuousClock.now + TestWaitLimit.hangGuard.duration
		while model.chat?.opening == .continuing, ContinuousClock.now < deadline {
			try await Task.sleep(for: .milliseconds(20))
		}
		#expect(model.chat?.turns.isEmpty == true)
		#expect(model.chat?.opening.notice == Catalog.chatNoticeNewConversationSuccess)
		#expect(model.newConversationUncertain == false)
		await model.loadHistory()
		guard case .loaded(let archived) = model.history else {
			Issue.record("History did not load: \(model.history)")
			return
		}
		#expect(archived.map(\.reason) == [.newConversation])
		#expect(archived.first?.firstQuestion == TutorialCopy.weekQuestion)
		let ref = try #require(archived.first?.id)
		guard case .loaded(let opened) = await model.loadArchivedConversation(ref) else {
			Issue.record("Archived conversation did not load")
			return
		}
		#expect(opened.turns.map(\.id) == [settled.id])
	}

	@Test func typedStartClearsTheDraftAndAFailedBoundaryKeepsTheConversation() async throws {
		let services = try services()
		let model = await model(services)
		await model.agreeAndStartChatting()
		model.draft.text = TutorialCopy.weekQuestion
		await model.send()
		let settled = try await settledTurn(model)
		let records = try #require(services.fixtureRecordFaults)
		try records.failAppends(ofKind: "windowStart")
		model.draft.text = "/start"
		await model.send()
		#expect(model.draft.text.isEmpty)
		try await until { model.newConversationUncertain }
		#expect(model.newConversationUncertain)
		#expect(model.chat?.turns.map(\.id) == [settled.id])
		#expect(model.chat?.opening == .continuing)
	}

	@Test func keepStoreRestoresRecordsAcrossServices() async throws {
		do {
			let first = await model(try services())
			await first.agreeAndStartChatting()
			first.draft.text = TutorialCopy.weekQuestion
			await first.send()
			let settled = try await settledTurn(first)
			#expect(replyText(settled.state)?.contains("Tuesday sweet spot") == true)
		}
		let (second, kept) = try await relaunch(.keep)
		let restored = try #require(await firstSnapshot(second, chat: .main))
		#expect(restored.turns.map(\.athleteText) == [TutorialCopy.weekQuestion])
		#expect(
			replyText(try #require(restored.turns.first?.state))?.contains("Tuesday sweet spot")
				== true)
		let reopened = await fixtureModel(
			environment: AppEnvironment(services: second, defaults: kept))
		try await observed(reopened)
		#expect(reopened.route == .chat)
		#expect(reopened.chat?.chat == .main)
	}

	@Test func freshStoreWipesRecordsAndSession() async throws {
		do {
			let first = await model(try services())
			await first.agreeAndStartChatting()
			first.draft.text = TutorialCopy.weekQuestion
			await first.send()
			_ = try await settledTurn(first)
		}
		let (second, wiped) = try await relaunch(.fresh)
		#expect(await firstSnapshot(second, chat: .main)?.turns.isEmpty == true)
		#expect(wiped.bool(forKey: ShellModel.onboardingCompletedKey) == false)
	}

	@Test func lockedKeychainThrowsInteractionNotAllowed() throws {
		let services = try services(keychain: .locked)
		#expect(throws: KeychainStoreError.keychain(errSecInteractionNotAllowed)) {
			try #require(services.fixture).secrets.creditsAccount()?.key
		}
	}

}

enum TutorialCopy {
	static let weekQuestion = "What did my training look like this week?"
}

func replyText(_ state: TurnState) -> String? {
	guard case .completed(let completed) = state, case .model(let text) = completed.reply else {
		return nil
	}
	return text
}

@MainActor
extension ShellModel {
	func agreeAndStartChatting() async {
		await startChatting()
		if route == .onboarding(.consent) {
			await acceptConsent()
			let deadline = ContinuousClock.now + TestWaitLimit.hangGuard.duration
			while route != .chat, ContinuousClock.now < deadline { await Task.yield() }
		}
		#expect(route == .chat)
	}
}
