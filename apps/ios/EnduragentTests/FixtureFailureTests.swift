import EnduragentCoach
import Foundation
import Testing

@testable import Enduragent

extension FixtureLaunchTests {
	@Test func providerFailureNoticeCarriesNoServerBody() async throws {
		var services = try services()
		let transport = FakeModelTransport()
		services.coach = try await failureCoach(transport, fixture: #require(services.fixture))
		let model = model(services)
		await model.agreeAndStartChatting()
		model.draft.text = "Give me a ride for tomorrow"
		await model.send()
		transport.script = Array(
			repeating: .fail(
				.http(status: 500, body: #"{"error":{"message":"upstream exploded at 10.0.0.7"}}"#)),
			count: 3)
		let turn = try await settledTurn(model)
		guard case .failed(let failed) = turn.state else {
			Issue.record("expected a failed turn, got \(turn.state)")
			return
		}
		#expect(failed.notice.key == Catalog.coachErrorProviderDown)
		#expect(failed.notice.vars.isEmpty)
		#expect(failed.notice.action == .tryAgain(turn.id))
	}

	@Test(arguments: [
		(
			"fixture:fail 401", Catalog.creditsErrorAccessRejected,
			Catalog.chatTurnRestorePurchases, 1
		),
		("fixture:fail 402", Catalog.creditsErrorExhausted, Catalog.chatTurnBuyCredits, 1),
		(
			"fixture:fail 429 1 x4", Catalog.coachErrorRateLimitSeconds,
			Catalog.chatTranscriptRetry, 4
		),
		("fixture:fail network x3", Catalog.coachErrorProviderDown, Catalog.chatTranscriptRetry, 3),
		("fixture:fail timeout x2", Catalog.coachErrorProviderDown, Catalog.chatTranscriptRetry, 2),
		("fixture:fail overflow x4", Catalog.coachErrorUnknown, Catalog.chatTranscriptRetry, 4 + 1),
	])
	func failDirectiveSettlesWithItsNotice(
		directive: String, key: CatalogKey, button: CatalogKey, requests: Int
	) async throws {
		let services = try services()
		let transport = try #require(services.fixtureTransport)
		let model = model(services)
		await model.agreeAndStartChatting()
		model.draft.text = directive
		await model.send()
		let failed = try await settledTurn(model)
		guard case .failed(let failure) = failed.state else {
			Issue.record("expected a failed turn, got \(failed.state)")
			return
		}
		#expect(failure.notice.key == key)
		#expect(failure.notice.action?.title == button)
		#expect(transport.requestCount == requests)
	}

	@Test func failDirectiveRetriesOnceThenReplies() async throws {
		let services = try services()
		let transport = try #require(services.fixtureTransport)
		let model = model(services)
		await model.agreeAndStartChatting()
		model.draft.text = "fixture:fail 500"
		await model.send()
		let answered = try await settledTurn(model)
		#expect(replyText(answered.state) == FirstWeekFixture.weekSummary)
		#expect(transport.requestCount == 2)
	}

	@Test func memoryThenFailSettlesSavedWorkWithoutTryAgain() async throws {
		let services = try services()
		let model = model(services)
		await model.agreeAndStartChatting()
		model.draft.text = "fixture:memory-then-fail"
		await model.send()
		let settled = try await settledTurn(model)
		guard case .savedWork(let savedWork) = settled.state else {
			Issue.record("expected saved work, got \(settled.state)")
			return
		}
		#expect(savedWork.outcome == .savedUnverified)
		#expect(savedWork.saved.memorySections == 1)
		#expect(savedWork.notice.key == Catalog.chatNoticeSavedUnverified)
		#expect(savedWork.notice.action == nil)
		#expect(!settled.state.retryable)
	}

	@Test func memoryThenHangStoppedOffersNoTryAgain() async throws {
		let model = model(try services())
		await model.agreeAndStartChatting()
		model.draft.text = "fixture:memory-then-hang"
		await model.send()
		let deadline = ContinuousClock.now + .seconds(10)
		while ContinuousClock.now < deadline {
			if case .processing(let running)? = model.chat?.turns.last?.state,
				running.activity == .generating(step: 2)
			{
				break
			}
			try await Task.sleep(for: .milliseconds(20))
		}
		await model.stop()
		let settled = try await settledTurn(model)
		guard case .interrupted(let stopped) = settled.state else {
			Issue.record("expected a stopped turn, got \(settled.state)")
			return
		}
		#expect(stopped.saved.memorySections == 1)
		#expect(stopped.notice.action == nil)
		#expect(!settled.state.retryable)
	}

	@Test func failDirectiveShowsTheProviderDownNoticeWithTryAgain() async throws {
		let services = try services()
		let model = model(services)
		await model.agreeAndStartChatting()
		model.draft.text = "fixture:fail 500 x3"
		await model.send()
		let failed = try await settledTurn(model)
		guard case .failed(let failure) = failed.state else {
			Issue.record("expected a failed turn, got \(failed.state)")
			return
		}
		#expect(failure.notice.key == Catalog.coachErrorProviderDown)
		#expect(failure.notice.action == .tryAgain(failed.id))
		await model.perform(.tryAgain(failed.id))
		let retried = try await settledTurn(model, after: failed.state)
		#expect(retried.id == failed.id)
		#expect(replyText(retried.state) == FirstWeekFixture.weekSummary)
	}
	private func failureCoach(_ transport: FakeModelTransport, fixture: FixtureServices)
		async throws
		-> Coach
	{
		let clock = FixtureClock(
			calendar: FixedClock(now: launch.clock, timeZone: FixtureLaunch.timeZone))
		let coach = Coach(
			sport: .cycling,
			ports: CoachPorts(
				records: .inMemory(deviceId: DeviceID()), secrets: fixture.secrets,
				models: .scripted(transport),
				training: FirstWeekFixture.training(fixture.intervals),
				credits: .fake(fixture.credits), host: fixture.host, clock: clock),
			builtInModel: AppServices.builtInModel, deviceLanguage: .en,
			coalescing: CoalescingPolicy(window: .milliseconds(200)))
		let services = AppServices(
			coach: coach, deviceCheck: FakeDeviceCheckTokenProvider(), clock: clock,
			leases: { fixture.host.leases }, packPrices: { _ in [:] })
		await model(services).agreeAndStartChatting()
		return coach
	}

}
