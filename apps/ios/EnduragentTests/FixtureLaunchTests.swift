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

	func relaunch(_ store: FixtureStorePolicy) throws -> (AppServices, UserDefaults) {
		var launch = launch
		launch.store = store
		let defaults = try launch.prepare()
		return (try AppServices.fixture(launch, defaults: defaults), defaults)
	}

	func model(_ services: AppServices) -> ShellModel {
		ShellModel(builder: builder(services))
	}

	func builder(_ services: AppServices) -> ServicesBuilder {
		ServicesBuilder(fixture: services, language: language, defaults: defaults)
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
		#expect(try await services.intervals.fetchAthlete().name == "Ada Kovač")
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
		#expect(model.athlete == nil)
		#expect(model.athleteFirstName.isEmpty)
	}

	@Test func alreadyGrantedWithStoredKeyShowsBalance() async throws {
		let services = try services()
		let credits = try #require(services.credits as? FakeCreditsClient)
		credits.grantResult = .success(.alreadyGranted)
		try services.secrets.storeOpenRouterKey("sk-or-test-0000")
		let model = model(services)
		await model.loadStarter()
		#expect(model.starterLine == "200 credits")
	}

	@Test func startChattingFailureShowsAthleteFacingCopy() throws {
		let builder = builder(try services())
		builder.completedServicesFailure = UnknownFinishReasonError(reason: "error")
		let model = ShellModel(builder: builder)
		model.startChatting()
		let failure = model.builder.phrasebook.say(Catalog.chatNoticeResponseFailure, [:])
		#expect(model.route == .onboarding(.notice))
		#expect(model.errorLine == failure)
		#expect(model.errorLine?.contains("UnknownFinishReasonError") != true)
		#expect(model.errorLine?.contains("String(describing:") != true)
	}

	@Test func intervalsLoadFailureShowsTheReason() async throws {
		let services = try services()
		let intervals = try #require(services.intervals as? FakeIntervalsClient)
		let failure = IntervalsError(
			code: "load_failed",
			details: "intervals.icu could not load today's training data."
		)
		intervals.loadFailure = failure
		defaults.set(true, forKey: ShellModel.onboardingCompletedKey)
		let model = model(services)
		await model.appear()
		#expect(model.route == .chat)
		#expect(model.errorLine == failure.details)
		#expect(model.athlete == nil)
		#expect(model.todayWellness == nil)
	}

	@Test func fixtureLaunchStaysOnNotice() throws {
		let model = model(try services())
		#expect(model.route == .onboarding(.notice))
	}

	@Test func coldStartRestoresChatAfterOnboarding() throws {
		defaults.set(true, forKey: ShellModel.onboardingCompletedKey)
		defaults.set("restored-chat", forKey: ShellModel.lastChatIdKey)
		let model = model(try services())
		#expect(model.route == .chat)
		#expect(model.chatId.rawValue == "restored-chat")
	}

	@Test func coldStartWithCompletedOnboardingAndNoChatUsesMain() throws {
		defaults.set(true, forKey: ShellModel.onboardingCompletedKey)
		let model = model(try services())
		#expect(model.route == .chat)
		#expect(model.chatId == .main)
	}

	@Test func coldStartRestoresTheTypedDraft() throws {
		defaults.set(true, forKey: ShellModel.onboardingCompletedKey)
		defaults.set("restored-chat", forKey: ShellModel.lastChatIdKey)
		let first = model(try services())
		first.draft.text = "Is Thursday still on?"
		first.draftChanged(from: "")
		let second = model(try services())
		#expect(second.draft == first.draft)
		#expect(second.draft.text == "Is Thursday still on?")
	}

	@Test func startChattingPersistsSessionForNextLaunch() throws {
		let services = try services()
		let first = model(services)
		first.startChatting()
		#expect(first.route == .chat)
		let second = model(services)
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
			builder: ServicesBuilder(fixture: second, language: language, defaults: kept))
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
			try services.secrets.openRouterKey()
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
	case .completed, .failed, .interrupted: true
	case .accepted, .processing: false
	}
}
