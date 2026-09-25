import EnduragentCoach
import Foundation
import Security
import Testing

@testable import Enduragent

@MainActor
struct FixtureLaunchTests {
	let launch: FixtureLaunch
	let defaults: UserDefaults
	let language = Language.uiTag(systemLanguages: Locale.preferredLanguages)

	init() throws {
		let stamp = UUID().uuidString
		launch = FixtureLaunch(
			name: FixtureLaunch.firstWeekName,
			store: .fresh,
			keychain: .unlocked,
			directory: FileManager.default.temporaryDirectory.appending(
				path: "enduragent-fixture-\(stamp)", directoryHint: .isDirectory),
			defaultsSuiteName: "enduragent.test.\(stamp)"
		)
		defaults = try launch.prepare()
	}

	private func services(
		store: FixtureStorePolicy = .fresh, keychain: FixtureKeychainPolicy = .unlocked
	) throws -> AppServices {
		var launch = launch
		launch.store = store
		launch.keychain = keychain
		return try AppServices.fixture(launch, defaults: defaults)
	}

	private func model(_ services: AppServices) -> ShellModel {
		ShellModel(builder: builder(services))
	}

	private func builder(_ services: AppServices) -> ServicesBuilder {
		ServicesBuilder(fixture: services, language: language, defaults: defaults)
	}

	@Test func fixtureArgumentBuildsCoachFromFakes() async throws {
		let services = try services()
		#expect(services.isFixture)
		#expect(try await services.intervals.fetchAthlete().name == "Ada Kovač")
		let model = model(services)
		await model.send("/plan")
		#expect(model.errorLine == "Plans arrive in the next TestFlight.")
		#expect(model.seam.transcript.isEmpty)
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

	@Test func sendShowsAthleteTextBeforeCoachReplies() async throws {
		let model = model(try services())
		let sendTask = Task { await model.send("fixture:slow") }
		try await Task.sleep(for: .milliseconds(40))
		#expect(model.composer.isEmpty)
		#expect(model.seam.phase == .streaming)
		#expect(model.seam.streamingText.isEmpty)
		#expect(model.isWaitingForCoach)
		#expect(model.seam.transcript.contains { $0.role == .user && $0.text == "fixture:slow" })
		await sendTask.value
		#expect(model.seam.transcript.contains { $0.role == .user && $0.text == "fixture:slow" })
		#expect(model.seam.transcript.contains { $0.role == .assistant && !$0.text.isEmpty })
		#expect(model.seam.streamingText.isEmpty)
		#expect(!model.isWaitingForCoach)
	}

	@Test func unknownFinishReasonDoesNotShowSwiftErrorDump() async throws {
		let services = try services()
		let transport = try #require(services.fixtureTransport)
		transport.failures = [UnknownFinishReasonError(reason: "error")]
		let model = model(services)
		model.startChatting()
		await model.send("Give me a ride for tomorrow")
		let failure = model.builder.phrasebook.say(Catalog.chatNoticeResponseFailure, [:])
		#expect(model.errorLine == failure)
		#expect(model.errorLine?.contains("UnknownFinishReasonError") != true)
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
		let first = model(try services(store: .keep))
		first.startChatting()
		await first.send(TutorialCopy.weekQuestion)
		#expect(first.seam.transcript.count == 2)
		let second = try services(store: .keep)
		let restored = await second.coach.history(chatId: first.chatId)
		#expect(restored.map(\.text).first == TutorialCopy.weekQuestion)
		#expect(restored.last?.text.contains("Tuesday sweet spot") == true)
	}

	@Test func freshStoreWipesRecordsAndSession() async throws {
		let first = model(try services(store: .keep))
		first.startChatting()
		await first.send(TutorialCopy.weekQuestion)
		let wiped = try launch.prepare()
		let second = try AppServices.fixture(launch, defaults: wiped)
		#expect(await second.coach.history(chatId: first.chatId).isEmpty)
		#expect(wiped.bool(forKey: ShellModel.onboardingCompletedKey) == false)
	}

	@Test func lockedKeychainThrowsInteractionNotAllowed() throws {
		let services = try services(keychain: .locked)
		#expect(throws: KeychainStoreError(status: errSecInteractionNotAllowed)) {
			try services.secrets.openRouterKey()
		}
	}

	@Test func slowDirectiveStreamsTheWeekSummaryWordByWord() async throws {
		let services = try services()
		let transport = try #require(services.fixtureTransport)
		let model = model(services)
		model.startChatting()
		await model.send("fixture:slow")
		#expect(transport.requests.count == 1)
		#expect(model.seam.transcript.last?.text == FirstWeekFixture.weekSummary)
		#expect(transport.requestDelay == FixtureDirector.slowFirstWordDelay)
		#expect(transport.deltaDelay == FixtureDirector.slowWordDelay)
		await model.send(TutorialCopy.weekQuestion)
		#expect(transport.requestDelay == nil)
		#expect(transport.deltaDelay == nil)
	}

	@Test func failDirectiveShowsTheResponseFailureNotice() async throws {
		let model = model(try services())
		model.startChatting()
		await model.send("fixture:fail 500")
		let failure = model.builder.phrasebook.say(Catalog.chatNoticeResponseFailure, [:])
		#expect(model.errorLine == failure)
		#expect(model.errorLine?.contains("OpenRouterHTTPError") != true)
	}

	@Test func storageDirectiveFailsTheNextAppendWithoutATurn() async throws {
		let services = try services()
		let transport = try #require(services.fixtureTransport)
		let records = try #require(services.fixtureRecordLog)
		let model = model(services)
		model.startChatting()
		await model.send("fixture:storage fail-next-append")
		#expect(transport.requests.isEmpty)
		#expect(model.seam.transcript.isEmpty)
		#expect(records.failNextAppend)
		await model.send(TutorialCopy.weekQuestion)
		#expect(model.errorLine?.contains("RecordStorageFault") == true)
		#expect(await services.coach.history(chatId: model.chatId).isEmpty)
	}

	@Test func plainTextAfterHangDirectiveAnswersNormally() async throws {
		let services = try services()
		let transport = try #require(services.fixtureTransport)
		let director = try #require(services.fixtureDirector)
		#expect(director.prepare(for: "fixture:hang") == .sendToCoach)
		#expect(transport.hangUntilCancelled)
		#expect(director.prepare(for: TutorialCopy.weekQuestion) == .sendToCoach)
		#expect(!transport.hangUntilCancelled)
		#expect(transport.script == [.text(FirstWeekFixture.weekSummary), .finish(reason: .stop)])
	}
}

private enum TutorialCopy {
	static let weekQuestion = "What did my training look like this week?"
}
