import EnduragentCoach
import Foundation
import Security
import Testing

@testable import Enduragent

@MainActor
@Suite(.serialized)
final class FixtureLaunchTests {
	let launch = FixtureLaunch(
		name: FixtureLaunch.firstWeekName,
		store: .fresh,
		keychain: .unlocked,
		directory: FileManager.default.temporaryDirectory.appending(
			path: "enduragent-fixture-test", directoryHint: .isDirectory),
		defaultsSuiteName: "enduragent.fixture.test"
	)
	let defaults: UserDefaults
	let language = Language.uiTag(systemLanguages: Locale.preferredLanguages)

	init() throws {
		defaults = try launch.prepare()
	}

	deinit {
		let launch = launch
		UserDefaults(suiteName: launch.defaultsSuiteName)?
			.removePersistentDomain(forName: launch.defaultsSuiteName)
		do {
			try FileManager.default.removeItem(at: launch.directory)
		} catch {
			Issue.record(error, "fixture directory cleanup")
		}
	}

	func services(keychain: FixtureKeychainPolicy = .unlocked) throws -> AppServices {
		var launch = launch
		launch.keychain = keychain
		return try AppServices.fixture(launch, defaults: defaults)
	}

	func relaunch(_ store: FixtureStorePolicy, keychain: FixtureKeychainPolicy = .unlocked) throws
		-> (AppServices, UserDefaults)
	{
		var launch = launch
		launch.store = store
		launch.keychain = keychain
		let defaults = try launch.prepare()
		return (try AppServices.fixture(launch, defaults: defaults), defaults)
	}

	func model(_ services: AppServices) -> ShellModel {
		ShellModel(builder: builder(services))
	}

	func builder(_ services: AppServices) -> ServicesBuilder {
		ServicesBuilder(services: services, language: language, defaults: defaults)
	}

	func settledTurn(
		_ model: ShellModel, after previous: TurnState? = nil, within limit: Duration = .seconds(20)
	) async throws -> TurnView {
		let deadline = ContinuousClock.now + limit
		while ContinuousClock.now < deadline {
			if let turn = model.chat?.turns.last, isSettled(turn.state), turn.state != previous {
				return turn
			}
			try await Task.sleep(for: .milliseconds(20))
		}
		return try #require(model.chat?.turns.last(where: { isSettled($0.state) }))
	}

	func settledTurn(_ model: ShellModel, at index: Int) async throws -> TurnView {
		let deadline = ContinuousClock.now + .seconds(20)
		while ContinuousClock.now < deadline {
			if let turns = model.chat?.turns, turns.indices.contains(index),
				isSettled(turns[index].state)
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
		let deadline = ContinuousClock.now + .seconds(5)
		while model.chat == nil, ContinuousClock.now < deadline {
			try await Task.sleep(for: .milliseconds(20))
		}
		try #require(model.chat != nil)
	}

	func firstTurn(_ model: ShellModel) async throws -> TurnView {
		let deadline = ContinuousClock.now + .seconds(5)
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
		#expect(services.isFixture)
		#expect(
			try await #require(services.fixtureDirector).intervals.fetchAthlete().name
				== "Ada Kovač")
		#expect(await services.coach.status().training == .unconnected)
		let model = model(services)
		#expect(model.route == .onboarding(.notice))
		#expect(model.chat == nil)
	}

	@Test func unknownFixtureNameThrows() throws {
		var unknown = launch
		unknown.name = "second-week"
		#expect(throws: FixtureLaunchError.self) {
			try AppServices.fixture(unknown, defaults: defaults)
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
		let services = try AppServices.fixture(widened, defaults: defaults)
		let model = model(services)
		model.startChatting()
		model.draft.text = TutorialCopy.weekQuestion
		await model.send()
		let turn = try await firstTurn(model)
		#expect(
			turn.state == .accepted(.collecting(until: services.clock.now.addingTimeInterval(2))))
		let settled = try await settledTurn(model)
		#expect(replyText(settled.state)?.contains("Tuesday sweet spot") == true)
	}

	@Test func starterScreenResolvesOnlyAfterGrant() async throws {
		let model = model(try services())
		#expect(model.starterResolved == false)
		await model.loadStarter()
		#expect(model.starterResolved)
		#expect(model.starterLine == "200 credits")
	}

	@Test func skippingConnectMovesToStarterWithoutAthlete() throws {
		let model = model(try services())
		model.continueNotice()
		model.skipConnect()
		#expect(model.route == .onboarding(.starter))
		#expect(model.connected == nil)
		#expect(model.athleteFirstName.isEmpty)
	}

	@Test func alreadyGrantedWithStoredKeyShowsBalance() async throws {
		let services = try services()
		let fixture = try #require(services.fixtureDirector)
		fixture.credits.grantResult = .success(.alreadyGranted)
		try fixture.secrets.storeOpenRouterKey("sk-or-test-0000")
		let model = model(services)
		await model.loadStarter()
		#expect(model.starterLine == "200 credits")
	}

	@Test func intervalsLoadFailureShowsACatalogNotice() async throws {
		let services = try services()
		let onboarding = model(services)
		onboarding.connectKey = "fixture"
		await onboarding.connect()
		#expect(onboarding.didConnect)
		try #require(services.fixtureDirector).intervals.loadFailure = IntervalsError(
			code: "load_failed",
			details: "intervals.icu could not load today's training data."
		)
		defaults.set(true, forKey: ShellModel.onboardingCompletedKey)
		let model = model(services)
		await model.appear()
		try await observed(model)
		#expect(model.route == .chat)
		#expect(model.errorLine == nil)
		#expect(model.status?.notice?.key == Catalog.coachErrorIntervalsTransient)
		#expect(
			model.status?.notice?.sentence(in: model.builder.phrasebook)
				== "Couldn't reach intervals.icu right now — try again shortly.")
		#expect(model.connected?.athleteName == nil)
	}

	@Test func creditsFailuresShowCatalogNotices() async throws {
		let services = try services()
		let fixture = try #require(services.fixtureDirector)
		fixture.credits.grantResult = .failure(.banned)
		fixture.credits.catalogResult = .failure(.unavailable)
		let model = model(services)
		await model.loadStarter()
		#expect(model.starterLine == "Credits are unavailable right now. Try again later.")
		await model.loadCredits()
		#expect(model.creditsNotice?.key == Catalog.creditsErrorUnavailable)
		#expect(model.errorLine == nil)
	}

	@Test func connectStoresTheKeyAndShowsTheAthleteAndToday() async throws {
		let services = try services()
		let model = model(services)
		model.continueNotice()
		model.connectKey = "fixture"
		await model.connect()
		#expect(model.didConnect)
		#expect(model.connectError == nil)
		#expect(model.connected?.athleteName == "Ada Kovač")
		#expect(model.connected?.today?.fitness == 42)
		#expect(model.athleteFirstName == "Ada")
		guard case .connected(_, .intervals(_, let athlete))? = model.status?.training else {
			Issue.record("expected a connected training account")
			return
		}
		#expect(athlete?.rawValue == "i1001")
	}

	@Test func blankConnectKeyShowsTheCatalogRejection() async throws {
		let model = model(try services())
		model.continueNotice()
		model.connectKey = "   "
		await model.connect()
		#expect(!model.didConnect)
		#expect(model.connectError == "intervals.icu did not accept that key.")
		#expect(model.connected == nil)
	}

	@Test func lockedKeychainOpensChatNotOnboarding() async throws {
		let first = model(try services())
		first.startChatting()
		first.draft.text = TutorialCopy.weekQuestion
		await first.send()
		_ = try await settledTurn(first)
		let (locked, kept) = try relaunch(.keep, keychain: .locked)
		let reopened = ShellModel(
			builder: ServicesBuilder(services: locked, language: language, defaults: kept))
		await reopened.appear()
		try await observed(reopened)
		#expect(reopened.route == .chat)
		#expect(reopened.chat?.turns.map(\.athleteText) == [TutorialCopy.weekQuestion])
		#expect(reopened.status?.setup == .accessTemporarilyUnavailable(.secureStorageLocked))
		#expect(
			reopened.status?.notice?.sentence(in: reopened.builder.phrasebook)
				== "Unlock your iPhone to continue. Your message is saved.")
	}

	@Test func keyStoredAfterLaunchReachesNextAttempt() async throws {
		let services = try services()
		let fixture = try #require(services.fixtureDirector)
		let model = model(services)
		model.startChatting()
		model.draft.text = TutorialCopy.weekQuestion
		await model.send()
		let unconnected = try await settledTurn(model)
		#expect(fixture.intervals.calls.isEmpty)
		guard
			case .replaced = await services.coach.changeTraining(
				.replace(apiKey: "fixture", athlete: .keyOwner))
		else {
			Issue.record("expected the key to be stored")
			return
		}
		model.draft.text = "How was my week?"
		await model.send()
		let connected = try await settledTurn(model, after: unconnected.state)
		#expect(replyText(connected.state) == FirstWeekFixture.weekSummary)
		#expect(
			fixture.intervals.calls.contains(.wellness(oldest: "1998-06-09", newest: "1998-06-15")))
	}

	@Test func fixtureLaunchStaysOnNotice() throws {
		let model = model(try services())
		#expect(model.route == .onboarding(.notice))
	}

	@Test func coldStartRestoresChatAfterOnboarding() async throws {
		defaults.set(true, forKey: ShellModel.onboardingCompletedKey)
		defaults.set("restored-chat", forKey: ShellModel.lastChatIdKey)
		let model = model(try services())
		try await observed(model)
		#expect(model.route == .chat)
		#expect(model.chatId.rawValue == "restored-chat")
	}

	@Test func coldStartWithCompletedOnboardingAndNoChatUsesMain() async throws {
		defaults.set(true, forKey: ShellModel.onboardingCompletedKey)
		let model = model(try services())
		try await observed(model)
		#expect(model.route == .chat)
		#expect(model.chatId == .main)
	}

	@Test func coldStartRestoresTheTypedDraft() async throws {
		defaults.set(true, forKey: ShellModel.onboardingCompletedKey)
		defaults.set("restored-chat", forKey: ShellModel.lastChatIdKey)
		let first = model(try services())
		first.draft.text = "Is Thursday still on?"
		first.draftChanged(from: "")
		let second = model(try services())
		try await observed(first)
		try await observed(second)
		#expect(second.draft == first.draft)
		#expect(second.draft.text == "Is Thursday still on?")
	}

	@Test func startChattingPersistsSessionForNextLaunch() async throws {
		let services = try services()
		let first = model(services)
		first.startChatting()
		#expect(first.route == .chat)
		let second = model(services)
		try await observed(first)
		try await observed(second)
		#expect(second.route == .chat)
		#expect(second.chatId == first.chatId)
		#expect(second.chatIndex.all().map(\.id) == [first.chatId.rawValue])
	}

	@Test func keepStoreRestoresRecordsAcrossServices() async throws {
		let first = model(try services())
		first.startChatting()
		first.draft.text = TutorialCopy.weekQuestion
		await first.send()
		let settled = try await settledTurn(first)
		#expect(replyText(settled.state)?.contains("Tuesday sweet spot") == true)
		let (second, kept) = try relaunch(.keep)
		let restored = try #require(await firstSnapshot(second, chat: first.chatId))
		#expect(restored.turns.map(\.athleteText) == [TutorialCopy.weekQuestion])
		#expect(
			replyText(try #require(restored.turns.first?.state))?.contains("Tuesday sweet spot")
				== true)
		let reopened = ShellModel(
			builder: ServicesBuilder(services: second, language: language, defaults: kept))
		try await observed(reopened)
		#expect(reopened.route == .chat)
		#expect(reopened.chatId == first.chatId)
	}

	@Test func freshStoreWipesRecordsAndSession() async throws {
		let first = model(try services())
		first.startChatting()
		first.draft.text = TutorialCopy.weekQuestion
		await first.send()
		_ = try await settledTurn(first)
		let (second, wiped) = try relaunch(.fresh)
		#expect(await firstSnapshot(second, chat: first.chatId)?.turns.isEmpty == true)
		#expect(wiped.bool(forKey: ShellModel.onboardingCompletedKey) == false)
	}

	@Test func lockedKeychainThrowsInteractionNotAllowed() throws {
		let services = try services(keychain: .locked)
		#expect(throws: KeychainStoreError(status: errSecInteractionNotAllowed)) {
			try #require(services.fixtureDirector).secrets.openRouterKey()
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

func isSettled(_ state: TurnState) -> Bool {
	switch state {
	case .completed, .savedWork, .failed, .interrupted: true
	case .accepted, .processing: false
	}
}
