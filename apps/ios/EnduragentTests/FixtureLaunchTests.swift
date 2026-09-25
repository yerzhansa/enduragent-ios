import EnduragentCoach
import Foundation
import Testing

@testable import Enduragent

@MainActor
struct FixtureLaunchTests {
	@Test func corruptChatIndexIsVisible() throws {
		let name = "enduragent.chat-index.\(UUID().uuidString)"
		let defaults = try #require(UserDefaults(suiteName: name))
		defaults.removePersistentDomain(forName: name)
		defaults.set(Data("{}".utf8), forKey: "enduragent.chatIndex")
		let index = ChatIndex(isFixture: false, defaults: defaults)
		#expect(index.loadError != nil)
		#expect(index.all().isEmpty)
	}

	@Test func fixtureArgumentBuildsCoachFromFakes() async throws {
		let services = try #require(AppServices.fixture(named: "first-week"))
		#expect(services.isFixture)
		#expect(try await services.intervals.fetchAthlete().name == "Ada Kovač")
		let language = Language.uiTag(systemLanguages: Locale.preferredLanguages)
		let model = ShellModel(builder: ServicesBuilder(fixture: services, language: language))
		await model.send("/plan")
		#expect(model.errorLine == "Plans arrive in the next TestFlight.")
		#expect(model.seam.transcript.isEmpty)
	}

	@Test func starterScreenResolvesOnlyAfterGrant() async throws {
		let services = try #require(AppServices.fixture(named: "first-week"))
		let language = Language.uiTag(systemLanguages: Locale.preferredLanguages)
		let model = ShellModel(builder: ServicesBuilder(fixture: services, language: language))
		#expect(model.starterResolved == false)
		await model.loadStarter()
		#expect(model.starterResolved)
		#expect(model.starterLine == "200 credits")
	}

	@Test func skippingConnectMovesToStarterWithoutAthlete() throws {
		let services = try #require(AppServices.fixture(named: "first-week"))
		let language = Language.uiTag(systemLanguages: Locale.preferredLanguages)
		let model = ShellModel(builder: ServicesBuilder(fixture: services, language: language))
		model.continueNotice()
		model.skipConnect()
		#expect(model.route == .onboarding(.starter))
		#expect(model.athlete == nil)
		#expect(model.athleteFirstName.isEmpty)
	}

	@Test func alreadyGrantedWithStoredKeyShowsBalance() async throws {
		let services = try #require(AppServices.fixture(named: "first-week"))
		let credits = try #require(services.credits as? FakeCreditsClient)
		credits.grantResult = .success(.alreadyGranted)
		try services.secrets.storeOpenRouterKey("sk-or-test-0000")
		let language = Language.uiTag(systemLanguages: Locale.preferredLanguages)
		let model = ShellModel(builder: ServicesBuilder(fixture: services, language: language))
		await model.loadStarter()
		#expect(model.starterLine == "200 credits")
	}

	@Test func sendShowsAthleteTextBeforeCoachReplies() async throws {
		let services = try #require(AppServices.fixture(named: "first-week"))
		let transport = try #require(services.fixtureTransport)
		transport.requestDelay = .milliseconds(250)
		let language = Language.uiTag(systemLanguages: Locale.preferredLanguages)
		let model = ShellModel(builder: ServicesBuilder(fixture: services, language: language))
		let sendTask = Task { await model.send("hi") }
		try await Task.sleep(for: .milliseconds(40))
		#expect(model.composer.isEmpty)
		#expect(model.seam.phase == .streaming)
		#expect(model.seam.streamingText.isEmpty)
		#expect(model.isWaitingForCoach)
		#expect(model.seam.transcript.contains { $0.role == .user && $0.text == "hi" })
		await sendTask.value
		#expect(model.seam.transcript.contains { $0.role == .user && $0.text == "hi" })
		#expect(model.seam.transcript.contains { $0.role == .assistant && !$0.text.isEmpty })
		#expect(model.seam.streamingText.isEmpty)
		#expect(!model.isWaitingForCoach)
	}

	@Test func unknownFinishReasonDoesNotShowSwiftErrorDump() async throws {
		let services = try #require(AppServices.fixture(named: "first-week"))
		let transport = try #require(services.fixtureTransport)
		transport.streamFailure = UnknownFinishReasonError(reason: "error")
		let language = Language.uiTag(systemLanguages: Locale.preferredLanguages)
		let model = ShellModel(builder: ServicesBuilder(fixture: services, language: language))
		model.startChatting()
		await model.send("Give me a ride for tomorrow")
		let failure = model.builder.phrasebook.say(Catalog.chatNoticeResponseFailure, [:])
		#expect(model.errorLine == failure)
		#expect(model.errorLine?.contains("UnknownFinishReasonError") != true)
	}

	@Test func startChattingFailureShowsAthleteFacingCopy() throws {
		let services = try #require(AppServices.fixture(named: "first-week"))
		let language = Language.uiTag(systemLanguages: Locale.preferredLanguages)
		let builder = ServicesBuilder(fixture: services, language: language)
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
		let services = try #require(AppServices.fixture(named: "first-week"))
		let intervals = try #require(services.intervals as? FakeIntervalsClient)
		let failure = IntervalsError(
			code: "load_failed",
			details: "intervals.icu could not load today's training data."
		)
		intervals.loadFailure = failure
		let language = Language.uiTag(systemLanguages: Locale.preferredLanguages)
		let suiteName = "enduragent.test.\(UUID().uuidString)"
		let suite = try #require(UserDefaults(suiteName: suiteName))
		defer { suite.removePersistentDomain(forName: suiteName) }
		suite.set(true, forKey: ShellModel.onboardingCompletedKey)
		let model = ShellModel(
			builder: ServicesBuilder(fixture: services, language: language),
			defaults: suite,
			persistSession: true
		)
		await model.appear()
		#expect(model.route == .chat)
		#expect(model.errorLine == failure.details)
		#expect(model.athlete == nil)
		#expect(model.todayWellness == nil)
	}

	@Test func fixtureLaunchStaysOnNotice() throws {
		let services = try #require(AppServices.fixture(named: "first-week"))
		let language = Language.uiTag(systemLanguages: Locale.preferredLanguages)
		let model = ShellModel(builder: ServicesBuilder(fixture: services, language: language))
		#expect(model.route == .onboarding(.notice))
	}

	@Test func coldStartRestoresChatAfterOnboarding() throws {
		let services = try #require(AppServices.fixture(named: "first-week"))
		let language = Language.uiTag(systemLanguages: Locale.preferredLanguages)
		let suiteName = "enduragent.test.\(UUID().uuidString)"
		let suite = try #require(UserDefaults(suiteName: suiteName))
		defer { suite.removePersistentDomain(forName: suiteName) }
		suite.set(true, forKey: ShellModel.onboardingCompletedKey)
		suite.set("restored-chat", forKey: ShellModel.lastChatIdKey)
		let model = ShellModel(
			builder: ServicesBuilder(fixture: services, language: language),
			defaults: suite,
			persistSession: true
		)
		#expect(model.route == .chat)
		#expect(model.chatId.rawValue == "restored-chat")
	}

	@Test func coldStartWithCompletedOnboardingAndNoChatUsesMain() throws {
		let services = try #require(AppServices.fixture(named: "first-week"))
		let language = Language.uiTag(systemLanguages: Locale.preferredLanguages)
		let suiteName = "enduragent.test.\(UUID().uuidString)"
		let suite = try #require(UserDefaults(suiteName: suiteName))
		defer { suite.removePersistentDomain(forName: suiteName) }
		suite.set(true, forKey: ShellModel.onboardingCompletedKey)
		let model = ShellModel(
			builder: ServicesBuilder(fixture: services, language: language),
			defaults: suite,
			persistSession: true
		)
		#expect(model.route == .chat)
		#expect(model.chatId == .main)
	}

	@Test func startChattingPersistsSessionForNextLaunch() throws {
		let services = try #require(AppServices.fixture(named: "first-week"))
		let language = Language.uiTag(systemLanguages: Locale.preferredLanguages)
		let suiteName = "enduragent.test.\(UUID().uuidString)"
		let suite = try #require(UserDefaults(suiteName: suiteName))
		defer { suite.removePersistentDomain(forName: suiteName) }
		let first = ShellModel(
			builder: ServicesBuilder(fixture: services, language: language),
			defaults: suite,
			persistSession: true
		)
		first.startChatting()
		#expect(first.route == .chat)
		let second = ShellModel(
			builder: ServicesBuilder(fixture: services, language: language),
			defaults: suite,
			persistSession: true
		)
		#expect(second.route == .chat)
		#expect(second.chatId == first.chatId)
	}
}
