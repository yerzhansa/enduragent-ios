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

	private func settledTurn(
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

	private func firstTurn(_ model: ShellModel) async throws -> TurnView {
		let deadline = ContinuousClock.now + .seconds(5)
		while model.chat?.turns.isEmpty ?? true, ContinuousClock.now < deadline {
			try await Task.sleep(for: .milliseconds(20))
		}
		return try #require(model.chat?.turns.first)
	}

	private func firstSnapshot(_ services: AppServices, chat: ChatID) async -> ChatSnapshot? {
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

	@Test func sendClearsDraftOnAccepted() async throws {
		let services = try services()
		let model = model(services)
		model.startChatting()
		model.draft.text = "fixture:slow"
		model.draftChanged(from: "")
		let draftId = model.draft.id
		#expect(model.drafts.load(model.chatId)?.text == "fixture:slow")
		await model.send()
		#expect(model.draft.text.isEmpty)
		#expect(model.draft.id != draftId)
		#expect(model.drafts.load(model.chatId) == nil)
		#expect(!model.notSent)
		let turn = try await firstTurn(model)
		#expect(turn.athleteText == "fixture:slow")
		#expect(!isSettled(turn.state))
		#expect(model.isWorking)
		#expect(services.fixtureTransport?.requests.isEmpty == true)
		let settled = try await settledTurn(model)
		#expect(replyText(settled.state) == FirstWeekFixture.weekSummary)
		#expect(!model.isWorking)
	}

	@Test func sendKeepsDraftWhenAcceptFails() async throws {
		let services = try services()
		let transport = try #require(services.fixtureTransport)
		let records = try #require(services.fixtureRecordLog)
		let model = model(services)
		model.startChatting()
		model.draft.text = "fixture:storage fail-next-append"
		model.draftChanged(from: "")
		let draft = model.draft
		await model.send()
		#expect(model.notSent)
		#expect(model.draft == draft)
		#expect(model.drafts.load(model.chatId) == draft)
		#expect(model.chat?.turns.isEmpty ?? true)
		#expect(transport.requests.isEmpty)
		#expect(!records.failNextAppend)
		#expect(await firstSnapshot(services, chat: model.chatId)?.turns.isEmpty == true)
		model.draft.text = TutorialCopy.weekQuestion
		model.draftChanged(from: draft.text)
		#expect(model.draft.id == draft.id)
		await model.send()
		#expect(!model.notSent)
		#expect(model.draft.text.isEmpty)
		#expect(try await firstTurn(model).athleteText == TutorialCopy.weekQuestion)
	}

	@Test func unknownFinishReasonDoesNotShowSwiftErrorDump() async throws {
		let services = try services()
		let transport = try #require(services.fixtureTransport)
		let model = model(services)
		model.startChatting()
		model.draft.text = "Give me a ride for tomorrow"
		transport.failures = [UnknownFinishReasonError(reason: "error")]
		await model.send()
		transport.failures = [UnknownFinishReasonError(reason: "error")]
		let turn = try await settledTurn(model)
		guard case .failed(let failed) = turn.state else {
			Issue.record("expected a failed turn, got \(turn.state)")
			return
		}
		#expect(failed.notice.key == Catalog.chatNoticeResponseFailure)
		#expect(failed.notice.action == .tryAgain(turn.id))
		#expect(model.errorLine == nil)
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
		let first = model(try services(store: .keep))
		first.startChatting()
		first.draft.text = TutorialCopy.weekQuestion
		await first.send()
		let settled = try await settledTurn(first)
		#expect(replyText(settled.state)?.contains("Tuesday sweet spot") == true)
		let second = try services(store: .keep)
		let restored = try #require(await firstSnapshot(second, chat: first.chatId))
		#expect(restored.turns.map(\.athleteText) == [TutorialCopy.weekQuestion])
		#expect(
			replyText(try #require(restored.turns.first?.state))?.contains("Tuesday sweet spot")
				== true)
	}

	@Test func keepStoreReopensAnUnstartedTurnAsAwaitingRestart() async throws {
		let first = model(try services(store: .keep))
		first.startChatting()
		first.draft.text = "fixture:hang"
		await first.send()
		let accepted = try await firstTurn(first)
		let second = try services(store: .keep)
		let reopened = try #require(await firstSnapshot(second, chat: first.chatId))
		#expect(reopened.turns.map(\.id) == [accepted.id])
		#expect(reopened.turns.first?.state == .accepted(.awaitingRestart))
	}

	@Test func freshStoreWipesRecordsAndSession() async throws {
		let first = model(try services(store: .keep))
		first.startChatting()
		first.draft.text = TutorialCopy.weekQuestion
		await first.send()
		_ = try await settledTurn(first)
		let wiped = try launch.prepare()
		let second = try AppServices.fixture(launch, defaults: wiped)
		#expect(await firstSnapshot(second, chat: first.chatId)?.turns.isEmpty == true)
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
		model.draft.text = "fixture:slow"
		await model.send()
		let settled = try await settledTurn(model)
		#expect(transport.requests.count == 1)
		#expect(replyText(settled.state) == FirstWeekFixture.weekSummary)
		#expect(transport.requestDelay == FixtureDirector.slowFirstWordDelay)
		#expect(transport.deltaDelay == FixtureDirector.slowWordDelay)
		model.draft.text = TutorialCopy.weekQuestion
		await model.send()
		#expect(transport.requestDelay == nil)
		#expect(transport.deltaDelay == nil)
	}

	@Test func failDirectiveShowsTheResponseFailureNoticeWithTryAgain() async throws {
		let services = try services()
		let model = model(services)
		model.startChatting()
		model.draft.text = "fixture:fail 500"
		await model.send()
		let failed = try await settledTurn(model)
		guard case .failed(let failure) = failed.state else {
			Issue.record("expected a failed turn, got \(failed.state)")
			return
		}
		#expect(failure.notice.key == Catalog.chatNoticeResponseFailure)
		#expect(failure.notice.action == .tryAgain(failed.id))
		#expect(model.errorLine == nil)
		await model.perform(.tryAgain(failed.id))
		let retried = try await settledTurn(model, after: failed.state)
		#expect(retried.id == failed.id)
		#expect(replyText(retried.state) == FirstWeekFixture.weekSummary)
		#expect(model.retryRefusal == nil)
	}

	@Test func plainTextAfterHangDirectiveAnswersNormally() async throws {
		let services = try services()
		let transport = try #require(services.fixtureTransport)
		let director = try #require(services.fixtureDirector)
		director.prepare(for: "fixture:hang")
		#expect(transport.hangUntilCancelled)
		director.prepare(for: TutorialCopy.weekQuestion)
		#expect(!transport.hangUntilCancelled)
		#expect(transport.script == [.text(FirstWeekFixture.weekSummary), .finish(reason: .stop)])
		director.prepare(for: "fixture:hang")
		director.prepareRetry(of: "fixture:hang")
		#expect(!transport.hangUntilCancelled)
		#expect(transport.script == [.text(FirstWeekFixture.weekSummary), .finish(reason: .stop)])
	}
}

private enum TutorialCopy {
	static let weekQuestion = "What did my training look like this week?"
}

private func replyText(_ state: TurnState) -> String? {
	guard case .completed(let completed) = state, case .model(let text) = completed.reply else {
		return nil
	}
	return text
}

private func isSettled(_ state: TurnState) -> Bool {
	switch state {
	case .completed, .failed, .interrupted: true
	case .accepted, .processing: false
	}
}
