import EnduragentCoach
import Testing

@testable import Enduragent

extension FixtureLaunchTests {
	@Test func onboardingShowsTheAIProviderNoticeBeforeChat() async throws {
		let services = try services()
		let model = model(services)
		await model.appear()
		#expect(model.route == .onboarding(.notice))
		model.continueNotice()
		model.skipConnect()
		await model.loadStarter()
		await model.startChatting()
		#expect(model.route == .onboarding(.consent(nil)))
		#expect(model.chat == nil)
		#expect(model.status?.setup == .needsProviderConsent)
		#expect(await services.coach.status().providerConsent == nil)
		model.declineConsent()
		#expect(model.route == .onboarding(.starter))
		#expect(await services.coach.status().providerConsent == nil)
		#expect(services.fixtureTransport?.requestCount == 0)
		await model.startChatting()
		#expect(model.route == .onboarding(.consent(nil)))
		await model.acceptConsent()
		#expect(model.route == .chat)
		#expect(
			await services.coach.status().providerConsent?.version == ProviderConsent.currentVersion
		)
		#expect(model.status?.setup == .ready)
		try await observed(model)
		#expect(model.chat?.chat == .main)
	}

	@Test func existingInstallIsAskedForConsentOnNextLaunch() async throws {
		defaults.set(true, forKey: ShellModel.onboardingCompletedKey)
		let (services, kept) = try relaunch(.keep)
		let launched = await AppLaunch.open(language: language) { (services, kept) }
		guard case .ready(let model) = launched else {
			Issue.record("Expected the existing install to open")
			return
		}
		#expect(model.route != .chat)
		await model.appear()
		#expect(model.route == .onboarding(.consent(nil)))
		#expect(model.chat == nil)
		model.declineConsent()
		#expect(model.route != .chat)
		let (next, nextDefaults) = try relaunch(.keep)
		let reopened = ShellModel(
			environment: AppEnvironment(services: next, language: language, defaults: nextDefaults))
		await reopened.appear()
		#expect(reopened.route == .onboarding(.consent(nil)))
		#expect(await next.coach.status().providerConsent == nil)
		#expect(next.fixtureTransport?.requestCount == 0)
	}

	@Test func consentWriteFailureKeepsTheNoticeAndCanBeRetried() async throws {
		let services = try services()
		let model = model(services)
		await model.startChatting()
		try #require(services.fixtureRecordFaults).failNextAppend = true
		await model.acceptConsent()
		#expect(model.route == .onboarding(.consent(nil)))
		#expect(model.consentNotSaved)
		#expect(await services.coach.status().providerConsent == nil)
		#expect(services.fixtureTransport?.requestCount == 0)
		await model.acceptConsent()
		#expect(model.route == .chat)
		#expect(!model.consentNotSaved)
	}

	@Test func consentRefusalReturnsToTheNoticeAndRetriesTheSameTurnAfterAgreement() async throws {
		let services = try services()
		let model = model(services)
		await model.startChatting()
		model.declineConsent()
		model.draft.text = TutorialCopy.weekQuestion
		await model.send()
		let refused = try #require(await firstSnapshot(services, chat: .main)?.turns.first)
		let deadline = ContinuousClock.now + .seconds(5)
		var snapshot = await firstSnapshot(services, chat: .main)
		while snapshot?.turns.first?.state.isSettled != true, ContinuousClock.now < deadline {
			try await Task.sleep(for: .milliseconds(20))
			snapshot = await firstSnapshot(services, chat: .main)
		}
		guard case .failed(let failure) = snapshot?.turns.first?.state else {
			Issue.record("Expected a consent refusal")
			return
		}
		#expect(failure.notice.key == Catalog.accessErrorProviderConsentRequired)
		#expect(failure.notice.action == .tryAgain(refused.id))
		#expect(services.fixtureTransport?.requestCount == 0)
		await model.perform(try #require(failure.notice.action))
		#expect(model.route == .onboarding(.consent(refused.id)))
		#expect(await services.coach.status().providerConsent == nil)
		await model.acceptConsent()
		#expect(model.route == .chat)
		let answered = try await settledTurn(model, after: snapshot?.turns.first?.state)
		#expect(answered.id == refused.id)
		#expect(replyText(answered.state) == FirstWeekFixture.weekSummary)
		#expect(model.chat?.turns.count == 1)
		#expect(services.fixtureTransport?.requestCount == 1)
	}
}
