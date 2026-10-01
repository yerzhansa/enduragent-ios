import EnduragentCoach
import EnduragentCoachFixtures
import Foundation
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
		#expect(model.route == .loading)
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
		#expect(await intervals.reads.calls.isEmpty)
		await model.sceneChanged(.becameActive)
		try await model.waitForStatus {
			if case .connected(let summary, _) = $0.training { return summary.athleteName == "Ada" }
			return false
		}
		#expect(await intervals.reads.calls == [.athlete, .wellness])
		#expect(model.connected?.athleteName == "Ada")
		#expect(model.status?.language == .fixed(.es))
		#expect(
			model.phrasebook.say(Catalog.chatComposerMessagePlaceholder, [:])
				== LanguageTag.es.phrasebook.say(Catalog.chatComposerMessagePlaceholder))
	}

	@Test func languageChoiceUpdatesWhileTrainingIsBlocked() async throws {
		let intervals = SlowTrainingClient()
		let model = try await returningModel(intervals: intervals)
		await model.appear()
		await intervals.reads.hold()
		let refreshing = Task { await model.sceneChanged(.becameActive) }
		await intervals.reads.waitUntilBlocked()
		let choosing = Task { await model.chooseLanguage(.fixed(.es)) }
		let deadline = ContinuousClock.now + .seconds(2)
		while model.status?.language != .fixed(.es), ContinuousClock.now < deadline {
			await Task.yield()
		}
		#expect(model.status?.language == .fixed(.es))
		#expect(
			model.phrasebook.say(Catalog.chatComposerMessagePlaceholder, [:])
				== LanguageTag.es.phrasebook.say(Catalog.chatComposerMessagePlaceholder))
		await intervals.reads.release()
		await refreshing.value
		await choosing.value
		#expect(model.status?.language == .fixed(.es))
	}

	@Test func activeLaunchRefreshesTrainingOnce() async throws {
		let intervals = SlowTrainingClient()
		let model = try await returningModel(intervals: intervals)
		await model.appear()
		await model.sceneChanged(.becameActive)
		#expect(await intervals.reads.calls == [.athlete, .wellness])
		try await model.waitForStatus {
			if case .connected(let summary, _) = $0.training { return summary.athleteName == "Ada" }
			return false
		}
		#expect(model.connected?.athleteName == "Ada")
		await model.sceneChanged(.enteredBackground)
		await model.sceneChanged(.becameActive)
		#expect(await intervals.reads.calls == [.athlete, .wellness, .athlete, .wellness])
	}

	@Test(arguments: [true, false])
	func visibleReviewOutcomeChangesWithTheLanguagePreference(expires: Bool) async throws {
		transport.respond = ScriptedReply.sequence(
			[
				.toolCall(
					name: "intervals_create_strength_workout",
					arguments: #"{"date":"1998-06-14","name":"Core","description":"20 minutes"}"#),
				.finish(reason: .toolCalls),
				.text("Confirm to add the core workout."),
				.finish(reason: .stop),
			], otherwise: transport.respond)
		let model = fixtureModel(
			environment: AppEnvironment(services: try services(), language: .en, defaults: defaults)
		)
		await model.agreeAndStartChatting()
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
		try await model.waitForStatus { $0.language == .fixed(.es) }
		#expect(model.status?.language == .fixed(.es))
		#expect(visible() == expected(.es))
	}

	private func returningModel(intervals: any IntervalsClient) async throws -> ShellModel {
		await fixtureModel(
			environment: AppEnvironment(services: try services(), language: .en, defaults: defaults)
		).agreeAndStartChatting()
		return fixtureModel(
			environment: AppEnvironment(
				services: try services(intervals: intervals), language: .en, defaults: defaults))
	}

	private func services(
		intervals: any IntervalsClient = FakeIntervalsClient(athleteName: "Ada", ftp: 250)
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
				training: .fake { _, _ in intervals }, credits: .fake(FakeCreditsClient()),
				host: ImmediateExecutionHost(), clock: clock),
			builtInModel: ModelID(rawValue: "test/coach-model"), deviceLanguage: .en,
			coalescing: CoalescingPolicy(window: .milliseconds(20)))
		return AppTestFixture.active.own(
			AppServices(
				coach: coach, deviceCheck: FakeDeviceCheckTokenProvider(), clock: clock,
				leases: { [] }, packPrices: { _ in [:] }))
	}
}
