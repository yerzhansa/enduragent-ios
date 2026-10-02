import EnduragentCoach
import EnduragentCoachFixtures
import Foundation
import Testing

@testable import Enduragent

extension FixtureLaunchTests {
	@Test func profileLoadFailureShowsItsCatalogNotice() async throws {
		let services = try services()
		let onboarding = model(services)
		await onboarding.agreeAndStartChatting()
		onboarding.connectKey = "fixture"
		await onboarding.connect()
		#expect(onboarding.didConnect)
		try #require(services.fixture).intervals.setProfileOutcome(
			.failure(URLError(.notConnectedToInternet))
		)
		defaults.set(true, forKey: ShellModel.onboardingCompletedKey)
		let model = model(services)
		await model.appear()
		await model.sceneChanged(.becameActive)
		try await model.waitForStatus { $0.notice?.key == Catalog.connectErrorProfileUnavailable }
		try await observed(model)
		#expect(model.route == .chat)
		#expect(model.status?.notice?.key == Catalog.connectErrorProfileUnavailable)
		#expect(
			model.status?.notice?.sentence(in: model.phrasebook)
				== "Your athlete profile is temporarily unavailable. Try again.")
		#expect(model.connected?.athleteName == nil)
		#expect(model.connected?.profile == .failed(.temporarilyUnavailable))
		let connection = try #require(model.connected)
		#expect(connection.action == .retry(connection.connectionID))
	}

	@Test func unreadableRecordStoreShowsTheStorageNoticeInsteadOfCrashing() async throws {
		var unreadable = launch
		unreadable.store = .unreadable
		let launched = await AppLaunch.open(language: .en) {
			let defaults = try unreadable.prepare()
			return (try fixtureServices(unreadable, defaults: defaults), defaults)
		}
		guard case .storageUnavailable(let phrasebook, _) = launched else {
			Issue.record("expected the storage notice, got a ready app")
			return
		}
		#expect(
			AthleteNotice.recordStoreUnavailable.map { $0.sentence(in: phrasebook) } == [
				"Conversation history is temporarily unavailable.", "Quit and reopen Enduragent.",
			])
		let live = await AppLaunch.open(language: .en) { throw CocoaError(.fileReadNoPermission) }
		guard case .storageUnavailable = live else {
			Issue.record("expected the storage notice for a live store failure")
			return
		}
	}

	@Test func creditsFailuresShowCatalogNotices() async throws {
		let services = try services()
		let fixture = try #require(services.fixture)
		fixture.credits.grantResult = .failure(.banned)
		fixture.credits.catalogResult = .failure(.unavailable)
		let model = model(services)
		await model.loadStarter()
		#expect(model.starterLine == "Credits are unavailable right now. Try again later.")
		await model.loadCredits()
		#expect(model.creditsNotice?.key == Catalog.creditsErrorUnavailable)
	}

	@Test func successfulConnectClearsSubmittedKey() async throws {
		let services = try services()
		let wellness = try #require(services.fixture).intervals.holdNextWellnessRead()
		defer { Task { await wellness.release() } }
		let model = model(services)
		await model.appear()
		model.continueNotice()
		model.connectKey = "fixture"
		await model.connect()
		try await wellness.waitForRead()
		try await model.waitForStatus {
			if case .connected(let summary, _) = $0.training {
				return summary.athleteName == "Ada Kovač"
			}
			return false
		}
		#expect(model.didConnect)
		#expect(model.connectKey.isEmpty)
		#expect(model.connectError == nil)
		#expect(model.connected?.athleteName == "Ada Kovač")
		#expect(model.connected?.wellness == .waiting)
		#expect(model.connected?.today == nil)
		await wellness.release()
		try await model.waitForStatus {
			if case .connected(let summary, _) = $0.training {
				return summary.today?.fitness == 42
			}
			return false
		}
		#expect(model.connected?.today?.fitness == 42)
		#expect(model.athleteFirstName == "Ada")
		guard case .connected(_, .intervals(_, let athlete))? = model.status?.training else {
			Issue.record("expected a connected training account")
			return
		}
		#expect(athlete?.rawValue == "i1001")
	}

	@Test func continuingConnectClearsAnyNewKey() async throws {
		let model = model(try services())
		await model.appear()
		model.continueNotice()
		model.connectKey = "fixture"
		await model.connect()
		try await model.waitForStatus {
			if case .connected(let summary, _) = $0.training {
				return summary.athleteName == "Ada Kovač"
			}
			return false
		}
		try #require(model.didConnect)
		model.connectKey = "edited-after-connect"
		model.continueConnect()
		#expect(model.connectKey.isEmpty)
		#expect(model.route == .onboarding(.starter))
		#expect(model.connected?.athleteName == "Ada Kovač")
	}

	@Test func blankConnectKeyShowsTheCatalogRejection() async throws {
		let model = model(try services())
		await model.appear()
		model.continueNotice()
		model.connectKey = "   "
		await model.connect()
		#expect(!model.didConnect)
		#expect(model.connectKey == "   ")
		#expect(model.connectError == "intervals.icu did not accept that key.")
		#expect(model.connected == nil)
	}

	@Test func lockedKeychainOpensChatNotOnboarding() async throws {
		do {
			let first = model(try services())
			await first.agreeAndStartChatting()
			first.draft.text = TutorialCopy.weekQuestion
			await first.send()
			_ = try await settledTurn(first)
		}
		let (locked, kept) = try await relaunch(.keep, keychain: .locked)
		let reopened = fixtureModel(
			environment: AppEnvironment(services: locked, language: language, defaults: kept))
		await reopened.appear()
		try await observed(reopened)
		#expect(reopened.route == .chat)
		#expect(reopened.chat?.turns.map(\.athleteText) == [TutorialCopy.weekQuestion])
		#expect(reopened.status?.setup == .accessTemporarilyUnavailable(.secureStorageLocked))
		#expect(
			reopened.status?.notice?.sentence(in: reopened.phrasebook)
				== "Unlock your iPhone to continue. Your message is saved.")
	}

	@Test func unlockingThePhoneClearsTheLockedNoticeWhenTheAppBecomesActive() async throws {
		defaults.set(true, forKey: ShellModel.onboardingCompletedKey)
		let services = try services(keychain: .locked)
		let fixture = try #require(services.fixture)
		let model = model(services)
		await model.agreeAndStartChatting()
		await model.appear()
		#expect(model.status?.setup == .accessTemporarilyUnavailable(.secureStorageLocked))
		fixture.secretBacking.locked = false
		await model.sceneChanged(.enteredBackground)
		#expect(model.status?.setup == .accessTemporarilyUnavailable(.secureStorageLocked))
		await model.sceneChanged(.becameActive)
		try await model.waitForStatus { $0.setup == .ready }
		#expect(model.status?.setup == .ready)
		#expect(model.status?.notice == nil)
	}

	@Test func keyStoredAfterLaunchReachesNextAttempt() async throws {
		let services = try services()
		let fixture = try #require(services.fixture)
		let model = model(services)
		await model.agreeAndStartChatting()
		model.draft.text = TutorialCopy.weekQuestion
		await model.send()
		let unconnected = try await settledTurn(model)
		#expect(fixture.intervals.calls.isEmpty)
		guard
			case .replaced = await services.coach.changeTraining(
				.replace(apiKey: "fixture", athlete: .keyOwner))
		else {
			Issue.record("expected the key to be stored")
			return
		}
		model.draft.text = "How was my week?"
		await model.send()
		let connected = try await settledTurn(model, after: unconnected.state)
		#expect(replyText(connected.state) == FirstWeekFixture.weekSummary)
		#expect(
			fixture.intervals.calls.contains(.wellness(oldest: "1998-06-09", newest: "1998-06-15")))
	}
}
