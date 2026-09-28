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
	func visibleReviewOutcomeChangesWithTheLanguagePreference(expires: Bool) async throws {
		transport.script = [
			.toolCall(
				name: "intervals_create_strength_workout",
				arguments: #"{"date":"1998-06-14","name":"Core","description":"20 minutes"}"#),
			.finish(reason: .toolCalls),
			.text("Confirm to add the core workout."),
			.finish(reason: .stop),
		]
		let model = ShellModel(
			environment: AppEnvironment(services: try services(), language: .en, defaults: defaults)
		)
		model.startChatting()
		await model.appear()
		model.draft.text = "Add a core workout tomorrow."
		await model.send()
		let deadline = ContinuousClock.now + .seconds(5)
		while model.chat?.review == nil || model.isWorking, ContinuousClock.now < deadline {
			try await Task.sleep(for: .milliseconds(10))
		}
		let review = try #require(model.chat?.review)
		try #require(!model.isWorking)
		await model.decide(.presented(review.ref))
		while model.chat?.review?.controls == ReviewControls.none, ContinuousClock.now < deadline {
			try await Task.sleep(for: .milliseconds(10))
		}
		guard case .approveOrCancel(let token)? = model.chat?.review?.controls else {
			Issue.record("The presented review has no approval control")
			return
		}
		if expires {
			clock.advance(by: 11 * 60)
		}
		await model.decide(.approve(token))
		if !expires {
			while model.chat?.notes.isEmpty != false, ContinuousClock.now < deadline {
				try await Task.sleep(for: .milliseconds(10))
			}
			try #require(model.chat?.notes.count == 1)
		}
		let visible = {
			expires
				? model.reviewNotice?.sentence(in: model.phrasebook)
				: model.chat?.notes.first?.sentence(in: model.phrasebook)
		}
		let expected = { (tag: LanguageTag) in
			let key = expires ? Catalog.coachConfirmationExpired : Catalog.coachConfirmationExecuted
			let summary = ReviewSummary.createStrengthWorkout(name: "Core", date: "1998-06-14")
			return tag.phrasebook.say(
				key, expires ? [:] : ["summary": summary.sentence(in: tag.phrasebook)])
		}
		#expect(visible() == expected(.en))
		await model.chooseLanguage(.fixed(.es))
		#expect(model.status?.language == .fixed(.es))
		#expect(visible() == expected(.es))
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
