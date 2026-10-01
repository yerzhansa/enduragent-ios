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
		#expect(model.route == .onboarding(.consent))
		#expect(model.chat == nil)
		#expect(model.status?.setup == .needsProviderConsent)
		#expect(try await services.coach.observedStatus().providerConsent == nil)
		model.declineConsent()
		#expect(model.route == .onboarding(.consentDeferred))
		#expect(try await services.coach.observedStatus().providerConsent == nil)
		#expect(services.fixtureTransport?.requestCount == 0)
		await model.acceptConsent()
		try await model.waitForStatus { !$0.needsProviderConsent }
		#expect(model.route == .chat)
		#expect(
			try await services.coach.observedStatus().providerConsent?.version
				== ProviderConsent.currentVersion
		)
		#expect(model.status?.setup == .ready)
		try await observed(model)
		#expect(model.chat?.chat == .main)
	}

	@Test func existingInstallIsAskedForConsentOnNextLaunch() async throws {
		defaults.set(true, forKey: ShellModel.onboardingCompletedKey)
		let (services, kept) = try await relaunch(.keep)
		let launched = await AppLaunch.open(language: language) { (services, kept) }
		guard case .ready(let model) = launched else {
			Issue.record("Expected the existing install to open")
			return
		}
		#expect(model.route != .chat)
		await model.appear()
		#expect(model.route == .onboarding(.consent))
		#expect(model.chat == nil)
		model.declineConsent()
		#expect(model.route != .chat)
		let (next, nextDefaults) = try await relaunch(.keep)
		let reopened = fixtureModel(
			environment: AppEnvironment(services: next, language: language, defaults: nextDefaults))
		await reopened.appear()
		#expect(reopened.route == .onboarding(.consent))
		#expect(try await next.coach.observedStatus().providerConsent == nil)
		#expect(next.fixtureTransport?.requestCount == 0)
	}

	@Test(arguments: [false, true])
	func consentWriteFailureKeepsTheNoticeAndCanBeRetried(deferred: Bool) async throws {
		let services = try services()
		let model = model(services)
		await model.startChatting()
		if deferred {
			model.declineConsent()
		}
		try #require(services.fixtureRecordFaults).failNextAppend = true
		await model.acceptConsent()
		#expect(model.route == .onboarding(deferred ? .consentDeferred : .consent))
		#expect(model.consentNotSaved)
		#expect(try await services.coach.observedStatus().providerConsent == nil)
		#expect(services.fixtureTransport?.requestCount == 0)
		await model.acceptConsent()
		try await model.waitForStatus { !$0.needsProviderConsent }
		#expect(model.route == .chat)
		#expect(!model.consentNotSaved)
		#expect(
			try await services.coach.observedStatus().providerConsent?.version
				== ProviderConsent.currentVersion
		)
		#expect(services.fixtureTransport?.requestCount == 0)
	}

	@Test func existingInstallCanDeferConsentWithoutRepeatingStarterCredits() async throws {
		defaults.set(true, forKey: ShellModel.onboardingCompletedKey)
		let (services, _) = try await relaunch(.keep)
		let model = model(services)
		await model.appear()
		#expect(model.route == .onboarding(.consent))
		model.declineConsent()
		#expect(
			model.route != .onboarding(.starter), "Declining must not repeat starter credits")
		#expect(model.route != .chat)
		#expect(model.route == .onboarding(.consentDeferred))
		#expect(!model.starterResolved)
		#expect(model.starterLine == nil)
		#expect(model.chat == nil)
		#expect(try await services.coach.observedStatus().providerConsent == nil)
		#expect(services.fixtureTransport?.requestCount == 0)
		await model.acceptConsent()
		try await model.waitForStatus { !$0.needsProviderConsent }
		#expect(model.route == .chat)
		#expect(!model.starterResolved)
		#expect(model.starterLine == nil)
		#expect(
			try await services.coach.observedStatus().providerConsent?.version
				== ProviderConsent.currentVersion
		)
		#expect(services.fixtureTransport?.requestCount == 0)
	}

	@Test func keptConsentRefusalRetriesTheSameTurnAfterAgreement() async throws {
		defaults.set(true, forKey: ShellModel.onboardingCompletedKey)
		let seeded = try services()
		_ = try await seeded.coach.send(
			Draft(id: DraftID(), text: TutorialCopy.weekQuestion), to: .main)
		let deadline = ContinuousClock.now + .seconds(5)
		var snapshot = await firstSnapshot(seeded, chat: .main)
		while snapshot?.turns.first?.state.isSettled != true, ContinuousClock.now < deadline {
			try await Task.sleep(for: .milliseconds(20))
			snapshot = await firstSnapshot(seeded, chat: .main)
		}
		guard case .failed(let failure) = snapshot?.turns.first?.state else {
			Issue.record("Expected a consent refusal")
			return
		}
		let refused = try #require(snapshot?.turns.first)
		#expect(failure.notice.key == Catalog.accessErrorProviderConsentRequired)
		#expect(failure.notice.action == .tryAgain(refused.id))
		#expect(seeded.fixtureTransport?.requestCount == 0)
		let (services, _) = try await relaunch(.keep)
		let model = model(services)
		await model.appear()
		#expect(model.route == .onboarding(.consent))
		#expect(try await services.coach.observedStatus().providerConsent == nil)
		await model.acceptConsent()
		try await observed(model)
		let kept = try #require(model.chat?.turns.first)
		#expect(kept.id == refused.id)
		#expect(kept.state == refused.state)
		#expect(services.fixtureTransport?.requestCount == 0)
		await model.perform(try #require(failure.notice.action))
		let answered = try await settledTurn(model, after: snapshot?.turns.first?.state)
		#expect(answered.id == refused.id)
		#expect(replyText(answered.state) == FirstWeekFixture.weekSummary)
		#expect(model.chat?.turns.count == 1)
		#expect(services.fixtureTransport?.requestCount == 1)
	}
}
