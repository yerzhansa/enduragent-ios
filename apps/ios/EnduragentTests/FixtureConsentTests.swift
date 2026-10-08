import EnduragentCoach
import EnduragentCoachFixtures
import Testing

@testable import Enduragent

extension FixtureLaunchTests {
	@Test(arguments: [FixtureKeychainPolicy.unavailable, .malformedAccess])
	func unreadableModelAccessRequiresConsentAfterRecovery(policy: FixtureKeychainPolicy)
		async throws
	{
		defaults.set(true, forKey: ShellModel.onboardingCompletedKey)
		var launch = launch
		launch.keychain = policy
		launch.accessMethod = .syncedOpenRouter
		let services = try fixtureServices(launch, defaults: defaults, language: .en)
		let fixture = try #require(services.fixture)
		let transport = try #require(services.fixtureTransport)
		let model = await model(services)
		try await observed(model)
		#expect(model.route == .chat)
		#expect(model.consentChallenge == nil)
		#expect(model.status.access.consent == .unavailable)
		let storageNotice =
			policy == .unavailable
			? Catalog.accessErrorStorageUnavailable : Catalog.accessErrorMalformed
		#expect(model.status.access.notice?.key == storageNotice)
		model.draft.text = TutorialCopy.weekQuestion
		await model.send()
		let blocked = try await settledTurn(model)
		guard case .failed(let storageFailure) = blocked.state else {
			Issue.record("Unreadable model access must refuse the turn")
			return
		}
		#expect(storageFailure.notice?.key == storageNotice)
		#expect(transport.requestCount == 0)
		let entry = try #require(ModelCatalog.bundled.orderedEntries.last)
		if policy == .unavailable {
			try #require(fixture.secretBacking).unavailable = false
		} else {
			try fixture.secrets.installOpenRouterChoice(
				model: entry.id, key: FirstWeekFixture.openRouterKey, catalog: .bundled)
		}
		await model.sceneChanged(.becameActive)
		try await model.waitForStatus { $0.needsProviderConsent }
		#expect(model.route == .onboarding(.consent))
		let challenge = try #require(model.consentChallenge)
		#expect(challenge.target.method == .openRouterAccount)
		#expect(challenge.target.entry == entry)
		#expect(transport.requestCount == 0)
		model.draft.text = TutorialCopy.weekQuestion
		await model.send()
		let refused = try await settledTurn(model, after: blocked.state)
		guard case .failed(let consentFailure) = refused.state else {
			Issue.record("Readable model access must refuse requests until consent is saved")
			return
		}
		#expect(consentFailure.notice?.key == Catalog.accessErrorProviderConsentRequired)
		#expect(consentFailure.notice?.actions == [.tryAgain(refused.id)])
		#expect(transport.requestCount == 0)
		await model.acceptConsent()
		try await until { model.route == .chat }
		await model.perform(try #require(consentFailure.notice?.actions.first))
		let answered = try await settledTurn(model, after: refused.state)
		#expect(answered.id == refused.id)
		#expect(replyText(answered.state) == FirstWeekFixture.weekSummary)
		#expect(transport.requestCount == 1)
	}

	@Test func onboardingShowsTheAIProviderNoticeBeforeChat() async throws {
		let services = try services()
		let model = await model(services)
		await model.appear()
		#expect(model.route == .onboarding(.notice))
		model.continueNotice()
		model.skipConnect()
		await model.loadStarter()
		await model.startChatting()
		#expect(model.route == .onboarding(.consent))
		#expect(model.chat == nil)
		#expect(model.status.setup == .needsProviderConsent)
		#expect(try await services.coach.observedStatus().acceptedConsent == nil)
		await model.declineConsent()
		#expect(model.route == .onboarding(.consentDeferred))
		#expect(try await services.coach.observedStatus().acceptedConsent == nil)
		#expect(services.fixtureTransport?.requestCount == 0)
		await model.acceptConsent()
		try await model.waitForStatus { !$0.needsProviderConsent }
		#expect(model.route == .chat)
		#expect(
			try await services.coach.observedStatus().acceptedConsent?.version
				== ProviderConsent.currentVersion
		)
		#expect(model.status.setup == .ready)
		try await observed(model)
		#expect(model.chat?.chat == .main)
	}

	@Test func existingInstallIsAskedForConsentOnNextLaunch() async throws {
		defaults.set(true, forKey: ShellModel.onboardingCompletedKey)
		do {
			let (services, kept) = try await relaunch(.keep)
			let launched = await AppLaunch.open(
				displayLocale: testLocaleResolver(languages: [language.rawValue])
			) { _ in
				(services, kept)
			}
			guard case .ready(let model) = launched else {
				Issue.record("Expected the existing install to open")
				return
			}
			#expect(model.route != .chat)
			await model.appear()
			#expect(model.route == .onboarding(.consent))
			#expect(model.chat == nil)
			await model.declineConsent()
			#expect(model.route != .chat)
		}
		let (next, nextDefaults) = try await relaunch(.keep)
		let reopened = await fixtureModel(
			environment: AppEnvironment(services: next, defaults: nextDefaults))
		await reopened.appear()
		#expect(reopened.route == .onboarding(.consent))
		#expect(try await next.coach.observedStatus().acceptedConsent == nil)
		#expect(next.fixtureTransport?.requestCount == 0)
	}

	@Test(arguments: [false, true])
	func consentWriteFailureKeepsTheNoticeAndCanBeRetried(deferred: Bool) async throws {
		let services = try services()
		let model = await model(services)
		await model.startChatting()
		if deferred {
			await model.declineConsent()
		}
		try #require(services.fixtureRecordFaults).failNextAppend = true
		await model.acceptConsent()
		#expect(model.route == .onboarding(deferred ? .consentDeferred : .consent))
		#expect(model.consentNotSaved)
		#expect(try await services.coach.observedStatus().acceptedConsent == nil)
		#expect(services.fixtureTransport?.requestCount == 0)
		await model.acceptConsent()
		try await model.waitForStatus { !$0.needsProviderConsent }
		#expect(model.route == .chat)
		#expect(!model.consentNotSaved)
		#expect(
			try await services.coach.observedStatus().acceptedConsent?.version
				== ProviderConsent.currentVersion
		)
		#expect(services.fixtureTransport?.requestCount == 0)
	}

	@Test func existingInstallCanDeferConsentWithoutRepeatingStarterCredits() async throws {
		defaults.set(true, forKey: ShellModel.onboardingCompletedKey)
		let (services, _) = try await relaunch(.keep)
		let model = await model(services)
		await model.appear()
		#expect(model.route == .onboarding(.consent))
		await model.declineConsent()
		#expect(
			model.route != .onboarding(.starter), "Declining must not repeat starter credits")
		#expect(model.route != .chat)
		#expect(model.route == .onboarding(.consentDeferred))
		#expect(!model.starterResolved)
		#expect(model.starterLine == nil)
		#expect(model.chat == nil)
		#expect(try await services.coach.observedStatus().acceptedConsent == nil)
		#expect(services.fixtureTransport?.requestCount == 0)
		await model.acceptConsent()
		try await model.waitForStatus { !$0.needsProviderConsent }
		#expect(model.route == .chat)
		#expect(!model.starterResolved)
		#expect(model.starterLine == nil)
		#expect(
			try await services.coach.observedStatus().acceptedConsent?.version
				== ProviderConsent.currentVersion
		)
		#expect(services.fixtureTransport?.requestCount == 0)
	}

	@Test func keptConsentRefusalRetriesTheSameTurnAfterAgreement() async throws {
		defaults.set(true, forKey: ShellModel.onboardingCompletedKey)
		let refused: TurnView
		do {
			let seeded = try services()
			_ = try await seeded.coach.send(
				Draft(id: DraftID(), text: TutorialCopy.weekQuestion), to: .main)
			let deadline = ContinuousClock.now + TestWaitLimit.hangGuard.duration
			var snapshot = await firstSnapshot(seeded, chat: .main)
			while snapshot?.turns.first?.state.isSettled != true, ContinuousClock.now < deadline {
				try await Task.sleep(for: .milliseconds(20))
				snapshot = await firstSnapshot(seeded, chat: .main)
			}
			refused = try #require(snapshot?.turns.first)
			#expect(seeded.fixtureTransport?.requestCount == 0)
		}
		guard case .failed(let failure) = refused.state else {
			Issue.record("Expected a consent refusal")
			return
		}
		#expect(failure.notice?.key == Catalog.accessErrorProviderConsentRequired)
		#expect(failure.notice?.actions == [.tryAgain(refused.id)])
		let (services, _) = try await relaunch(.keep)
		let model = await model(services)
		await model.appear()
		#expect(model.route == .onboarding(.consent))
		#expect(try await services.coach.observedStatus().acceptedConsent == nil)
		await model.acceptConsent()
		try await observed(model)
		let kept = try #require(model.chat?.turns.first)
		#expect(kept.id == refused.id)
		#expect(kept.state == refused.state)
		#expect(services.fixtureTransport?.requestCount == 0)
		await model.perform(try #require(failure.notice?.actions.first))
		let answered = try await settledTurn(model, after: refused.state)
		#expect(answered.id == refused.id)
		#expect(replyText(answered.state) == FirstWeekFixture.weekSummary)
		#expect(model.chat?.turns.count == 1)
		#expect(services.fixtureTransport?.requestCount == 1)
	}
}

extension FixtureLaunchTests {
	@Test(arguments: [false, true])
	func openRouterConsentNamesSavedChoiceAndRetriesOnlyAfterAgreement(synced: Bool) async throws {
		var launch = launch
		launch.signInOutcome = .success
		launch.accessMethod = synced ? .syncedOpenRouter : .credits
		let services = try fixtureServices(launch, defaults: defaults, language: .en)
		let model = await model(services)
		await model.appear()
		model.continueNotice()
		model.skipConnect()
		await model.loadStarter()
		if !synced {
			await model.chooseAccess(.signInToOpenRouter)
			try await model.waitForStatus { $0.access.savedMethod == .openRouterAccount }
		}
		await model.startChatting()
		let challenge = try #require(model.consentChallenge)
		let entry = try #require(
			synced
				? ModelCatalog.bundled.orderedEntries.last
				: ModelCatalog.bundled.orderedEntries.first)
		#expect(challenge.target.entry == entry)
		#expect(challenge.target.method == .openRouterAccount)
		if !synced { #expect(challenge.target.entry.id == AppServices.builtInModel) }
		#expect(model.route == .onboarding(.consent))
		let outcome = try await services.coach.send(
			Draft(id: DraftID(), text: TutorialCopy.weekQuestion), to: .main)
		guard case .accepted(let turn) = outcome else {
			Issue.record("Expected the saved turn to reach the consent gate")
			return
		}
		let deadline = ContinuousClock.now + TestWaitLimit.hangGuard.duration
		var snapshot = await firstSnapshot(services, chat: .main)
		while snapshot?.turns.first?.state.isSettled != true, ContinuousClock.now < deadline {
			try await Task.sleep(for: .milliseconds(20))
			snapshot = await firstSnapshot(services, chat: .main)
		}
		let refused = try #require(snapshot?.turns.first)
		guard case .failed(let failure) = refused.state else {
			Issue.record("Expected a provider consent refusal")
			return
		}
		#expect(failure.notice?.actions == [.tryAgain(turn)])
		await model.declineConsent()
		#expect(model.route == .onboarding(.consentDeferred))
		#expect(services.fixtureTransport?.requestCount == 0)
		try #require(services.fixtureRecordFaults).failNextAppend = true
		await model.acceptConsent()
		#expect(model.consentNotSaved)
		#expect(model.route == .onboarding(.consentDeferred))
		#expect(services.fixtureTransport?.requestCount == 0)
		await model.acceptConsent()
		try await observed(model)
		await model.perform(try #require(failure.notice?.actions.first))
		let answered = try await settledTurn(model, after: refused.state)
		#expect(answered.id == turn)
		#expect(replyText(answered.state) == FirstWeekFixture.weekSummary)
		#expect(services.fixtureTransport?.requestCount == 1)
		let accepted = try #require(model.status.acceptedConsent)
		#expect(accepted.target == challenge.target)
	}
}
