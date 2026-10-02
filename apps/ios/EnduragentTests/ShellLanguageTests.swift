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
	func launchShowsSavedLanguageWhileProfileAndWellnessAreWaiting(completedOnboarding: Bool)
		async throws
	{
		let intervals = FakeIntervalsClient(athleteName: "Ada", ftp: 250)
		let profile = intervals.holdNextProfileRead()
		let wellness = intervals.holdNextWellnessRead()
		defer {
			Task {
				await profile.release()
				await wellness.release()
			}
		}
		try await services(intervals: intervals).coach.setLanguage(.fixed(.es))
		defaults.set(completedOnboarding, forKey: ShellModel.onboardingCompletedKey)
		let launch = await AppLaunch.open(language: .en) {
			(try services(intervals: intervals), defaults)
		}
		guard case .ready(let model) = launch else {
			Issue.record("The saved language did not reopen into a ready shell")
			return
		}
		#expect(intervals.profileReadCount == 0)
		#expect(intervals.wellnessReadCount == 0)
		#expect(
			model.phrasebook.say(Catalog.chatComposerMessagePlaceholder, [:])
				== LanguageTag.es.phrasebook.say(Catalog.chatComposerMessagePlaceholder))
		await model.appear()
		try await profile.waitForRead()
		#expect(model.connected?.profile == .waiting)
		#expect(model.connected?.today == nil)
		#expect(model.status?.language == .fixed(.es))
		#expect(intervals.profileReadCount == 1)
		#expect(intervals.wellnessReadCount == 0)
		await profile.release()
		try await wellness.waitForRead()
		try await model.waitForStatus {
			if case .connected(let summary, _) = $0.training { return summary.athleteName == "Ada" }
			return false
		}
		#expect(model.connected?.wellness == .waiting)
		#expect(model.connected?.athleteName == "Ada")
		await wellness.release()
		try await model.waitForStatus {
			if case .connected(let summary, _) = $0.training {
				return summary.wellness == .available(.noData(on: "1998-06-13"))
			}
			return false
		}
		#expect(intervals.profileReadCount == 1)
		#expect(intervals.wellnessReadCount == 1)
		#expect(model.status?.language == .fixed(.es))
		#expect(
			model.phrasebook.say(Catalog.chatComposerMessagePlaceholder, [:])
				== LanguageTag.es.phrasebook.say(Catalog.chatComposerMessagePlaceholder))
	}

	@Test func languageChoiceUpdatesWhileTrainingIsBlocked() async throws {
		let intervals = FakeIntervalsClient(athleteName: "Ada", ftp: 250)
		let profile = intervals.holdNextProfileRead()
		defer { Task { await profile.release() } }
		let model = try await returningModel(intervals: intervals)
		await model.appear()
		try await profile.waitForRead()
		await model.chooseLanguage(.fixed(.es))
		try await model.waitForStatus { $0.language == .fixed(.es) }
		#expect(model.status?.language == .fixed(.es))
		#expect(model.connected?.profile == .waiting)
		#expect(intervals.wellnessReadCount == 0)
		#expect(
			model.phrasebook.say(Catalog.chatComposerMessagePlaceholder, [:])
				== LanguageTag.es.phrasebook.say(Catalog.chatComposerMessagePlaceholder))
		await profile.release()
		try await model.waitForStatus {
			if case .connected(let summary, _) = $0.training {
				return summary.wellness == .available(.noData(on: "1998-06-13"))
			}
			return false
		}
		#expect(model.status?.language == .fixed(.es))
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
		#expect(intervals.profileReadCount == 1)
		#expect(intervals.wellnessReadCount == 1)
		await model.sceneChanged(.becameActive)
		#expect(intervals.profileReadCount == 2)
		#expect(intervals.wellnessReadCount == 2)
		#expect(model.connected?.athleteName == "Ada")
		await model.sceneChanged(.enteredBackground)
		await model.sceneChanged(.becameActive)
		#expect(intervals.profileReadCount == 3)
		#expect(intervals.wellnessReadCount == 3)
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
		let deadline = ContinuousClock.now + TestWaitLimit.hangGuard.duration
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
			try #require(model.chat?.notes.values.flatMap { $0 }.count == 1)
		}
		let visible = {
			expires
				? model.reviewNotice?.sentence(in: model.phrasebook)
				: model.chat?.notes.values.flatMap { $0 }.first?.sentence(in: model.phrasebook)
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
