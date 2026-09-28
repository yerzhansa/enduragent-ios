import EnduragentCoach
import Foundation
import Testing

@testable import Enduragent

extension FixtureLaunchTests {
	@Test func clockArgumentMovesTheFixedClockAtLaunch() throws {
		let suite = "enduragent.fixture.clock.test"
		let arguments = try #require(UserDefaults(suiteName: suite))
		defer { arguments.removePersistentDomain(forName: suite) }
		arguments.set(FixtureLaunch.firstWeekName, forKey: FixtureLaunch.nameArgumentKey)
		arguments.set("tomorrow", forKey: FixtureLaunch.clockArgumentKey)
		#expect(throws: FixtureLaunchError.self) { try FixtureLaunch.fromArguments(arguments) }
		arguments.set("1998-06-16T04:20:00Z", forKey: FixtureLaunch.clockArgumentKey)
		let parsed = try #require(try FixtureLaunch.fromArguments(arguments))
		#expect(parsed.clock == "1998-06-16T04:20:00Z")
		var moved = launch
		moved.clock = parsed.clock
		#expect(
			try AppServices.fixture(moved, defaults: defaults).clock.now == instant(parsed.clock))
		#expect(try services().clock.now == instant(FixtureLaunch.defaultClock))
	}

	@Test func languageChoiceRewritesTheChatAndTheNextReplyRequest() async throws {
		let services = try services()
		let model = model(services)
		model.startChatting()
		#expect(model.phrasebook.say(Catalog.chatViewTitle, [:]) == "Chat")
		model.draft.text = "/language"
		await model.send()
		#expect(model.showLanguage)
		#expect(model.draft.text.isEmpty)
		#expect(await model.refreshStatus().language == .automatic)
		await model.chooseLanguage(.fixed(.fr))
		#expect(model.status?.language == .fixed(.fr))
		#expect(model.phrasebook.say(Catalog.chatViewTitle, [:]) == "Conversation")
		#expect(
			model.phrasebook.say(Catalog.chatComposerMessagePlaceholder, [:])
				== "Écris à ton coach")
		model.draft.text = TutorialCopy.weekQuestion
		await model.send()
		_ = try await settledTurn(model)
		#expect(
			services.fixtureTransport?.lastReplyLanguage?.hasPrefix(
				"The athlete chose French (Français).") == true)
		let (kept, keptDefaults) = try relaunch(.keep)
		let reopened = ShellModel(
			builder: ServicesBuilder(services: kept, language: language, defaults: keptDefaults))
		#expect(reopened.route == .chat)
		await reopened.appear()
		#expect(reopened.status?.language == .fixed(.fr))
		#expect(reopened.phrasebook.say(Catalog.chatViewTitle, [:]) == "Conversation")
	}

	@Test func aLanguageThatCannotBeSavedKeepsTheCurrentChoice() async throws {
		let services = try services()
		let model = model(services)
		model.startChatting()
		await model.refreshStatus()
		services.fixtureRecordLog?.failAppends(ofKind: SyncedKind.languagePreference)
		await model.chooseLanguage(.fixed(.de))
		#expect(
			model.languageNotSavedLine
				== "Couldn't save Deutsch. The app and replies still follow your iPhone's language. Try again."
		)
		#expect(model.status?.language == .automatic)
		model.draft.text = "/language"
		await model.send()
		#expect(model.languageNotSavedLine == nil)
	}

	@Test func sessionSettingsSaveAndSurviveARelaunch() async throws {
		let services = try services()
		let model = model(services)
		model.startChatting()
		let stored = await model.refreshStatus().session
		#expect(stored.text(for: .dailyResetHour) == "4")
		try await model.saveSession(try stored.replacing(.dailyResetHour, with: "6"))
		#expect(model.status?.session.dailyResetHour.hour == 6)
		let (kept, _) = try relaunch(.keep)
		#expect(await kept.coach.status().session.text(for: .dailyResetHour) == "6")
	}

	@Test func aDailyResetAfterAClockMoveOpensAFreshSession() async throws {
		var evening = launch
		evening.clock = "1998-06-16T01:40:00Z"
		let first = model(try AppServices.fixture(evening, defaults: defaults))
		first.startChatting()
		first.draft.text = TutorialCopy.weekQuestion
		await first.send()
		let earlier = try await settledTurn(first)
		var morning = launch
		morning.store = .keep
		morning.clock = "1998-06-16T02:20:00Z"
		let keptDefaults = try morning.prepare()
		let second = ShellModel(
			builder: ServicesBuilder(
				services: try AppServices.fixture(morning, defaults: keptDefaults),
				language: language,
				defaults: keptDefaults))
		try await observed(second)
		second.draft.text = TutorialCopy.weekQuestion
		await second.send()
		try await until(within: .seconds(20)) {
			second.chat?.opening == .afterAutomaticReset(.daily)
				&& second.chat?.turns.first?.state.isSettled == true
		}
		let reset = try #require(second.chat?.turns.first)
		#expect(reset.id != earlier.id)
		#expect(second.chat?.turns.map(\.id) == [reset.id])
		await second.loadHistory()
		guard case .loaded(let archived) = second.history else {
			Issue.record("History did not load: \(second.history)")
			return
		}
		#expect(archived.map(\.reason) == [.closedAfterBreak])
		#expect(archived.first?.turns.map(\.id) == [earlier.id])
	}

	private func instant(_ text: String) throws -> Date {
		let formatter = ISO8601DateFormatter()
		formatter.formatOptions = [.withInternetDateTime]
		return try #require(formatter.date(from: text))
	}

	private func until(
		within limit: Duration = .seconds(5), _ condition: () -> Bool
	) async throws {
		let deadline = ContinuousClock.now + limit
		while !condition(), ContinuousClock.now < deadline {
			try await Task.sleep(for: .milliseconds(20))
		}
		try #require(condition())
	}
}
