import EnduragentCoach
import Foundation
import Testing

@testable import Enduragent

@MainActor
@Suite(.serialized)
final class ShellLanguageTests {
	private let domain = "enduragent.shell.language.tests"
	private let defaults: UserDefaults
	private let records = InMemoryRecordLog()
	private let transport = FakeModelTransport()
	private let clock = FixedClock(
		now: "1998-06-13T08:00:00+02:00", timeZone: "Europe/Amsterdam")

	init() throws {
		defaults = try #require(UserDefaults(suiteName: domain))
		defaults.removePersistentDomain(forName: domain)
	}

	deinit {
		UserDefaults(suiteName: domain)?.removePersistentDomain(forName: domain)
	}

	@Test func relaunchDoesNotRenderAutomaticOverASavedFixedPreference() async throws {
		try await services().coach.setLanguage(.fixed(.es))
		defaults.set(true, forKey: ShellModel.onboardingCompletedKey)
		let launch = await AppLaunch.open(language: .en) {
			(try services(), defaults)
		}
		guard case .ready(let model) = launch else {
			Issue.record("The saved language did not reopen into a ready shell")
			return
		}
		#expect(model.route == .chat)
		#expect(
			model.phrasebook.say(Catalog.chatComposerMessagePlaceholder, [:])
				== LanguageTag.es.phrasebook.say(Catalog.chatComposerMessagePlaceholder))
		await model.appear()
		#expect(
			model.phrasebook.say(Catalog.chatComposerMessagePlaceholder, [:])
				== LanguageTag.es.phrasebook.say(Catalog.chatComposerMessagePlaceholder))
	}

	@Test(arguments: [true, false])
	func launchShowsTheSavedLanguageBeforeSlowTrainingLoads(completedOnboarding: Bool) async throws
	{
		let intervals = SlowTrainingClient()
		try await services(intervals: intervals).coach.setLanguage(.fixed(.es))
		defaults.set(completedOnboarding, forKey: ShellModel.onboardingCompletedKey)
		let launch = await AppLaunch.open(language: .en) {
			(try services(intervals: intervals), defaults)
		}
		guard case .ready(let model) = launch else {
			Issue.record("The saved language did not reopen into a ready shell")
			return
		}
		#expect(await intervals.reads.calls.isEmpty)
		#expect(
			model.phrasebook.say(Catalog.chatComposerMessagePlaceholder, [:])
				== LanguageTag.es.phrasebook.say(Catalog.chatComposerMessagePlaceholder))
		await model.appear()
		#expect(await intervals.reads.calls == [.athlete, .wellness])
		#expect(model.connected?.athleteName == "Ada")
		#expect(model.status?.language == .fixed(.es))
		#expect(
			model.phrasebook.say(Catalog.chatComposerMessagePlaceholder, [:])
				== LanguageTag.es.phrasebook.say(Catalog.chatComposerMessagePlaceholder))
	}

	@Test(arguments: [true, false])
	func visibleConfirmationChangesWithTheLanguagePreference(expires: Bool) async throws {
		transport.script = [
			.toolCall(
				name: "intervals_create_strength_workout",
				arguments: #"{"date":"1998-06-14","name":"Core","description":"20 minutes"}"#),
			.finish(reason: .toolCalls),
			.text("Confirm to add the core workout."),
			.finish(reason: .stop),
		]
		let model = ShellModel(
			builder: ServicesBuilder(services: try services(), language: .en, defaults: defaults))
		model.startChatting()
		await model.appear()
		model.draft.text = "Add a core workout tomorrow."
		await model.send()
		let deadline = ContinuousClock.now + .seconds(5)
		while model.visibleProposal == nil || model.isWorking, ContinuousClock.now < deadline {
			try await Task.sleep(for: .milliseconds(10))
		}
		let pending = try #require(model.visibleProposal)
		try #require(!model.isWorking)
		if expires {
			clock.advance(by: 11 * 60)
		}
		await model.confirmPending()
		let key = expires ? Catalog.coachConfirmationExpired : Catalog.coachConfirmationExecuted
		let variables = expires ? [:] : ["summary": pending.summary]
		#expect(model.confirmLine == LanguageTag.en.phrasebook.say(key, variables))
		await model.chooseLanguage(.fixed(.es))
		#expect(model.status?.language == .fixed(.es))
		#expect(model.confirmLine == LanguageTag.es.phrasebook.say(key, variables))
	}

	private func services(
		intervals: any IntervalsClient = FakeIntervalsClient(athleteName: "Ada", ftp: 250)
	) throws -> AppServices {
		let secrets = FakeSecretStore()
		try secrets.storeOpenRouterKey("sk-or-test-shell-language")
		try secrets.storeIntervalsConnection(
			IntervalsConnection(
				id: ConnectionID(), credential: .apiKey("icu-test-key"), selection: .keyOwner,
				resolvedAthlete: IntervalsAthleteID(rawValue: "i1001")))
		let coach = Coach(
			sport: .cycling,
			ports: CoachPorts(
				records: records, secrets: secrets, models: .scripted(transport),
				training: .fake { _, _ in intervals }, credits: .fake(FakeCreditsClient()),
				host: ImmediateExecutionHost(), clock: clock),
			builtInModel: ModelID(rawValue: "test/coach-model"), deviceLanguage: .en,
			coalescing: CoalescingPolicy(window: .milliseconds(20)))
		return AppServices(
			coach: coach, deviceCheck: FakeDeviceCheckTokenProvider(), clock: clock,
			fixtureDirector: nil, leases: { [] })
	}
}
