import EnduragentCoach
import EnduragentCoachFixtures
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
			try fixtureServices(moved, defaults: defaults).clock.now == instant(parsed.clock))
		#expect(try services().clock.now == instant(FixtureLaunch.defaultClock))
	}

	@Test func languageChoiceRewritesTheChatAndTheNextReplyRequest() async throws {
		do {
			let services = try services()
			let model = await model(services)
			await model.agreeAndStartChatting()
			#expect(model.phrasebook.say(Catalog.chatViewTitle, [:]) == "Chat")
			model.draft.text = "/language"
			await model.send()
			#expect(model.showLanguage)
			#expect(model.draft.text.isEmpty)
			#expect(model.status.language == .automatic)
			await model.chooseLanguage(.fixed(.fr))
			try await model.waitForStatus { $0.language == .fixed(.fr) }
			#expect(model.status.language == .fixed(.fr))
			#expect(model.phrasebook.say(Catalog.chatViewTitle, [:]) == "Conversation")
			#expect(
				model.phrasebook.say(Catalog.chatComposerMessagePlaceholder, [:])
					== "Écris à ton coach")
			model.draft.text = TutorialCopy.weekQuestion
			await model.send()
			_ = try await settledTurn(model)
			#expect(
				services.fixtureTransport?.lastReplyLanguage?.hasPrefix(
					"Reply in French (Français).") == true)
		}
		let (kept, keptDefaults) = try await relaunch(.keep)
		let reopened = await fixtureModel(
			environment: AppEnvironment(services: kept, defaults: keptDefaults))
		#expect(reopened.route == .loading)
		await reopened.appear()
		#expect(reopened.route == .chat)
		#expect(reopened.status.language == .fixed(.fr))
		#expect(reopened.phrasebook.say(Catalog.chatViewTitle, [:]) == "Conversation")
	}

	@Test func aLanguageThatCannotBeSavedKeepsTheCurrentChoice() async throws {
		let services = try services()
		let model = await model(services)
		await model.agreeAndStartChatting()
		let records = try #require(services.fixtureRecordFaults)
		try records.failAppends(ofKind: "languagePreference")
		await model.chooseLanguage(.fixed(.de))
		#expect(
			model.languageNotSavedLine
				== "Couldn't save your choice on this iPhone, so nothing was changed. Try again."
		)
		#expect(model.status.language == .automatic)
		model.draft.text = "/language"
		await model.send()
		#expect(model.languageNotSavedLine == nil)
	}

	@Test func sessionSettingsSaveAndSurviveARelaunch() async throws {
		do {
			let services = try services()
			let model = await model(services)
			await model.agreeAndStartChatting()
			let stored = try #require(model.status).session
			#expect(stored.text(for: .contextWindowOverride) == "")
			try await model.saveSession(try stored.replacing(.contextWindowOverride, with: "64000"))
			try await model.waitForStatus { $0.session.contextWindowOverride?.tokens == 64_000 }
			#expect(model.status.session.contextWindowOverride?.tokens == 64_000)
		}
		let (kept, _) = try await relaunch(.keep)
		#expect(
			try await kept.coach.observedStatus().session.text(for: .contextWindowOverride)
				== "64000")
	}

	@Test func aThirteenHourGapAfterARelaunchKeepsTheConversation() async throws {
		var evening = launch
		evening.clock = "1998-06-15T18:00:00Z"
		let earlier: TurnView
		do {
			let first = await model(try fixtureServices(evening, defaults: defaults))
			await first.agreeAndStartChatting()
			first.draft.text = TutorialCopy.weekQuestion
			await first.send()
			earlier = try await settledTurn(first)
		}
		let (morning, keptDefaults) = try await relaunch(.keep, clock: "1998-06-16T07:00:00Z")
		let second = await fixtureModel(
			environment: AppEnvironment(
				services: morning, defaults: keptDefaults))
		try await observed(second)
		second.draft.text = TutorialCopy.weekQuestion
		await second.send()
		try await until(within: .hangGuard) {
			second.chat?.turns.count == 2 && second.chat?.turns.last?.state.isSettled == true
		}
		#expect(second.chat?.opening == .continuing)
		#expect(second.chat?.turns.first?.id == earlier.id)
		await second.loadHistory()
		guard case .loaded(let archived) = second.history else {
			Issue.record("History did not load: \(second.history)")
			return
		}
		#expect(archived.isEmpty)
	}

	private func instant(_ text: String) throws -> Date {
		let formatter = ISO8601DateFormatter()
		formatter.formatOptions = [.withInternetDateTime]
		return try #require(formatter.date(from: text))
	}
}
