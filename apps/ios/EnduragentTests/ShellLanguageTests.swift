import EnduragentCoach
import EnduragentCoachFixtures
import Foundation
import Synchronization
import Testing

@testable import Enduragent

@MainActor
@Suite(.serialized, FixtureTestScope())
final class ShellLanguageTests {
	private var directory: URL { AppTestFixture.active.launch.directory }
	private var defaults: UserDefaults { AppTestFixture.active.defaults }
	private var records: RecordStore { AppTestFixture.active.records }
	private let transport = FakeModelTransport()
	private let clock = FixedClock(
		now: "1998-06-13T08:00:00+02:00", timeZone: "Europe/Amsterdam")

	@Test func settingsLanguagePickerPreservesTheNavigationAndConversation() async throws {
		let model = await fixtureModel(
			environment: AppEnvironment(services: try services(), defaults: defaults)
		)
		await model.agreeAndStartChatting()
		model.draft.text = "How was my training week?"
		await model.send()
		try await until { model.chat?.turns.last?.state.isSettled == true }
		let turn = try #require(model.chat?.turns.last)
		model.draft.text = "My next question"
		model.open(.settings)
		model.openLanguagePicker()
		#expect(model.showLanguage)
		#expect(model.navigation == [.settings])
		#expect(model.chat?.turns.last?.id == turn.id)
		#expect(model.chat?.turns.count == 1)
		#expect(model.draft.text == "My next question")
		#expect(model.languagePreference == .automatic)
	}

	@Test func relaunchDoesNotRenderAutomaticOverASavedFixedPreference() async throws {
		try await services().coach.setLanguage(.fixed(.es))
		defaults.set(true, forKey: ShellModel.onboardingCompletedKey)
		let launch = await AppLaunch.open(displayLocale: testLocaleResolver(languages: ["en"])) {
			_ in
			(try services(), defaults)
		}
		guard case .ready(let model) = launch else {
			Issue.record("The saved language did not reopen into a ready shell")
			return
		}
		#expect(model.route == .loading)
		#expect(
			model.phrasebook.say(Catalog.chatComposerMessagePlaceholder, [:])
				== LanguageTag.es.phrasebook.say(Catalog.chatComposerMessagePlaceholder))
		await model.appear()
		#expect(
			model.phrasebook.say(Catalog.chatComposerMessagePlaceholder, [:])
				== LanguageTag.es.phrasebook.say(Catalog.chatComposerMessagePlaceholder))
	}

	@Test func activationRefreshesTrainingOnceAfterInitialObservation() async throws {
		let intervals = FakeIntervalsClient(athleteName: "Ada", ftp: 250)
		let model = try await returningModel(intervals: intervals)
		await model.appear()
		try await model.waitForStatus {
			if case .connected(let summary, _) = $0.training {
				return summary.wellness == .available(.noData(on: "1998-06-13"))
			}
			return false
		}
		#expect(intervals.count(of: .profile) == 1)
		#expect(intervals.count(of: .wellness) == 1)
		intervals.rename(athleteTo: "Ada Lovelace")
		await model.sceneChanged(.becameActive)
		try await model.waitForStatus {
			if case .connected(let summary, _) = $0.training {
				return summary.athleteName == "Ada Lovelace"
					&& summary.wellness == .available(.noData(on: "1998-06-13"))
			}
			return false
		}
		#expect(intervals.count(of: .profile) == 2)
		#expect(intervals.count(of: .wellness) == 2)
		#expect(model.connected?.athleteName == "Ada Lovelace")
		intervals.rename(athleteTo: "Ada")
		await model.sceneChanged(.enteredBackground)
		await model.sceneChanged(.becameActive)
		try await model.waitForStatus {
			if case .connected(let summary, _) = $0.training {
				return summary.athleteName == "Ada"
					&& summary.wellness == .available(.noData(on: "1998-06-13"))
			}
			return false
		}
		#expect(intervals.count(of: .profile) == 3)
		#expect(intervals.count(of: .wellness) == 3)
		#expect(model.connected?.athleteName == "Ada")
	}

	@Test func visibleReviewOutcomeChangesWithTheLanguagePreference() async throws {
		let phone = ShellDisplayPhone()
		phone.change(languages: ["en"], region: "en_US")
		transport.respond = ScriptedReply.sequence(
			FirstWeekFixture.preparation + [
				.text("Approve the workout to add it."), .finish(reason: .stop),
			], otherwise: transport.respond)
		var model = await fixtureModel(
			environment: AppEnvironment(
				services: try services(displayLocale: phone.resolve), defaults: defaults)
		)
		await model.agreeAndStartChatting()
		await model.appear()
		model.draft.text = "Add a workout tomorrow."
		await model.send()
		try await until { model.chat?.review != nil && !model.isWorking }
		let review = try #require(model.chat?.review)
		let calls = transport.requestCount
		await model.chooseLanguage(.fixed(.fr))
		try await model.waitForStatus { $0.language == .fixed(.fr) }
		model = await fixtureModel(
			environment: AppEnvironment(
				services: try services(displayLocale: phone.resolve), defaults: defaults))
		#expect(model.displayLocale.language == .fr)
		await model.appear()
		try await until { model.chat?.review != nil }
		let restored = try #require(model.chat?.review)
		#expect(restored.ref.review == review.ref.review)
		#expect(
			restored.cards.first?.lines(in: model.displayLocale).contains(
				"- 10m progressif 60.5-80.5% 90rpm Warmup ramp 1.5") == true)
		phone.change(languages: ["en"], region: "fr_FR")
		NotificationCenter.default.post(
			name: NSLocale.currentLocaleDidChangeNotification, object: nil)
		try await model.waitForStatus {
			$0.displayLocale.regionalConventions.region?.identifier == "FR"
		}
		#expect(
			restored.cards.first?.lines(in: model.displayLocale).contains(
				"- 10m progressif 60,5-80,5% 90rpm Warmup ramp 1.5") == true)
		await model.chooseLanguage(.fixed(.en))
		try await model.waitForStatus { $0.language == .fixed(.en) }
		#expect(transport.requestCount == calls)
		await model.decide(.presented(restored.ref))
		try await until { model.chat?.review?.controls != ReviewControls.none }
		guard case .armed(.approveOrCancel, let token)? = model.chat?.review?.controls else {
			Issue.record("The presented review has no approval control")
			return
		}
		await model.decide(.approve(token))
		try await until { model.chat?.notes.isEmpty == false }
		try #require(model.chat?.notes.values.flatMap { $0 }.count == 1)
		let visible = {
			model.chat?.notes.values.flatMap { $0 }.first?.sentence(in: model.displayLocale)
		}
		#expect(visible() == "Endurance with tempo, 16/06/1998: change saved.")
		await model.chooseLanguage(.fixed(.es))
		try await model.waitForStatus { $0.language == .fixed(.es) }
		#expect(model.status.language == .fixed(.es))
		#expect(visible() == "Endurance with tempo, 16/06/1998: cambio guardado.")
	}

	@Test func retainedNumbersAndDatesRefreshWithLocaleNotificationsAndLanguageChoices()
		async throws
	{
		let phone = ShellDisplayPhone()
		let intervals = FakeIntervalsClient(athleteName: "Ada", ftp: 250)
		intervals.seedWellness([(date: "1998-06-13", fitness: 1234.5, fatigue: 2345.5)])
		let credits = FakeCreditsClient()
		credits.grantResult = .success(.minted(Credits(units: 12345)))
		credits.balanceResult = .success(CreditBalance(credits: Credits(units: 12345)))
		let built = try services(
			intervals: intervals, displayLocale: phone.resolve, credits: credits)
		try await built.coach.setLanguage(.fixed(.fr))
		let model = await fixtureModel(
			environment: AppEnvironment(services: built, defaults: defaults))
		#expect(model.displayLocale.language == .fr)
		#expect(model.historyDate("2026-03-04") == "mercredi, mars 4, 2026")
		await model.appear()
		await model.loadStarter()
		await model.loadCredits()
		try #require(model.creditsNotice == nil)
		#expect(model.starterLine == "12,345 crédits")
		#expect(model.creditsBalanceLine == "12,345 crédits")
		#expect(
			model.wellnessLine(Catalog.onboardingConnectFitness, value: 1234.5)
				== "Condition physique 1,235")
		phone.change(languages: ["en"], region: "fr_FR")
		NotificationCenter.default.post(
			name: NSLocale.currentLocaleDidChangeNotification, object: nil)
		try await model.waitForStatus {
			$0.displayLocale.regionalConventions.region?.identifier == "FR"
		}
		#expect(model.displayLocale.language == .fr)
		#expect(model.historyDate("2026-03-04") == "mercredi 4 mars 2026")
		#expect(model.starterLine == "12 345 crédits")
		#expect(model.creditsBalanceLine == "12 345 crédits")
		#expect(
			model.wellnessLine(Catalog.onboardingConnectFitness, value: 1234.5)
				== "Condition physique 1 235")
		await model.chooseLanguage(.fixed(.en))
		try await model.waitForStatus { $0.language == .fixed(.en) }
		#expect(model.historyDate("2026-03-04") == "Wednesday 4 March 2026")
		#expect(model.starterLine == "12 345 credits")
		#expect(model.creditsBalanceLine == "12 345 credits")
		#expect(
			model.wellnessLine(Catalog.onboardingConnectFitness, value: 1234.5) == "Fitness 1 235")
		await model.chooseLanguage(.automatic)
		try await model.waitForStatus { $0.language == .automatic }
		phone.change(languages: ["fr"], region: "en_US")
		await model.sceneChanged(.becameActive)
		try await model.waitForStatus { $0.displayLocale.language == .fr }
		#expect(model.historyDate("2026-03-04") == "mercredi, mars 4, 2026")
		#expect(model.starterLine == "12,345 crédits")
	}

	private func returningModel(intervals: FakeIntervalsClient) async throws -> ShellModel {
		await fixtureModel(
			environment: AppEnvironment(services: try services(), defaults: defaults)
		).agreeAndStartChatting()
		return await fixtureModel(
			environment: AppEnvironment(
				services: try services(intervals: intervals), defaults: defaults))
	}

	private func services(
		intervals: FakeIntervalsClient = FakeIntervalsClient(athleteName: "Ada", ftp: 250),
		displayLocale: @escaping DisplayLocaleResolver = testLocaleResolver(),
		credits: FakeCreditsClient = FakeCreditsClient()
	) throws -> AppServices {
		let secrets = try ICloudKeychainStore.fixture(directory: directory).store
		try secrets.storeCreditsAccount(
			CreditsAccount(
				appAccountToken: UUID(),
				key: "sk-or-test-shell-language"))
		try secrets.storeIntervalsConnection(
			IntervalsConnection(
				id: ConnectionID(), credential: .apiKey("icu-test-key"), selection: .keyOwner,
				resolvedAthlete: IntervalsAthleteID(rawValue: "i1001")))
		let coach = Coach(
			sport: .cycling,
			ports: CoachPorts(
				records: records, secrets: secrets, models: .scripted(transport),
				training: .fake { _, _ in intervals }, credits: .fake(credits),
				host: ImmediateExecutionHost(), clock: clock, support: .inMemory(app: .fixture)),
			builtInModel: ModelID(rawValue: "test/coach-model"), displayLocale: displayLocale,
			coalescing: CoalescingPolicy(window: .milliseconds(20)))
		return AppTestFixture.active.own(
			AppServices(
				coach: coach, device: DeviceDefaults(suiteName: FixtureLaunch.defaultsSuiteName),
				deviceCheck: FakeDeviceCheckTokenProvider(),
				clock: clock,
				leases: { [] }))
	}
}

private final class ShellDisplayPhone: Sendable {
	private let state = Mutex((languages: ["fr"], region: Locale(identifier: "en_US")))

	func resolve(_ preference: LanguagePreference) -> DisplayLocale {
		state.withLock {
			DisplayLocale(
				preference: preference, preferredLanguages: $0.languages,
				regionalConventions: $0.region)
		}
	}

	func change(languages: [String], region: String) {
		state.withLock { $0 = (languages, Locale(identifier: region)) }
	}
}
