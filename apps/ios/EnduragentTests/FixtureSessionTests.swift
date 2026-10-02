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

	@Test(arguments: [false, true], [LanguagePreference.fixed(.fr), .automatic])
	func languageChoiceRewritesTheChatAndTheNextReplyRequest(
		fromSettings: Bool, preference: LanguagePreference
	) async throws {
		do {
			let services = try fixtureServices(launch, defaults: defaults, language: .fr)
			let model = fixtureModel(
				environment: AppEnvironment(services: services, language: .fr, defaults: defaults))
			await model.agreeAndStartChatting()
			try await observed(model)
			await model.chooseLanguage(.fixed(.de))
			try await model.waitForStatus { $0.language == .fixed(.de) }
			await openLanguage(model, fromSettings: fromSettings)
			#expect(model.showLanguage)
			#expect(model.chat?.turns.isEmpty == true)
			await model.chooseLanguage(preference)
			try await model.waitForStatus { $0.language == preference }
			#expect(model.languagePreference == preference)
			#expect(model.phrasebook.say(Catalog.chatViewTitle) == "Conversation")
		}
		let (kept, keptDefaults) = try await relaunch(.keep, language: .fr)
		let launched = await AppLaunch.open(systemLanguages: ["ru", "fr", "en"]) { _ in
			(kept, keptDefaults)
		}
		guard case .ready(let opened) = launched else {
			Issue.record("The saved preference did not reopen into a ready shell")
			return
		}
		let reopened = fixture.own(opened)
		#expect(reopened.route == .loading)
		#expect(reopened.languagePreference == preference)
		#expect(
			reopened.phrasebook.say(Catalog.chatComposerMessagePlaceholder) == "Écris à ton coach")
		try await observed(reopened)
		#expect(reopened.chat?.turns.isEmpty == true)
		let messages =
			preference == .automatic
			? [TutorialCopy.weekQuestion, "今週の練習はどうでしたか？", "/review"]
			: [TutorialCopy.weekQuestion]
		for (index, message) in messages.enumerated() {
			reopened.draft.text = message
			await reopened.send()
			_ = try await settledTurn(reopened, at: index)
			let instruction = try #require(kept.fixtureTransport?.lastReplyLanguage)
			#expect(instruction.hasPrefix(frenchInstruction(for: preference)))
			#expect(reopened.languagePreference == preference)
		}
	}

	@Test(arguments: [false, true], [LanguagePreference.fixed(.de), .automatic])
	func aLanguageThatCannotBeSavedKeepsTheCurrentChoice(
		fromSettings: Bool, attempted: LanguagePreference
	) async throws {
		do {
			let services = try fixtureServices(launch, defaults: defaults, language: .fr)
			let model = fixtureModel(
				environment: AppEnvironment(services: services, language: .fr, defaults: defaults))
			await model.agreeAndStartChatting()
			try await observed(model)
			await model.chooseLanguage(.fixed(.en))
			try await model.waitForStatus { $0.language == .fixed(.en) }
			let records = try #require(services.fixtureRecordFaults)
			records.failNextAppend = true
			await openLanguage(model, fromSettings: fromSettings)
			await model.chooseLanguage(attempted)
			#expect(!records.failNextAppend)
			#expect(
				model.languageNotSavedLine
					== "Couldn't save your choice on this iPhone, so nothing was changed. Try again."
			)
			#expect(model.languagePreference == .fixed(.en))
			model.draft.text = TutorialCopy.weekQuestion
			await model.send()
			_ = try await settledTurn(model)
			#expect(
				services.fixtureTransport?.lastReplyLanguage?.hasPrefix(
					"The athlete chose English (English).") == true)
			await openLanguage(model, fromSettings: fromSettings)
			#expect(model.languageNotSavedLine == nil)
		}
		let (kept, keptDefaults) = try await relaunch(.keep, language: .fr)
		let launched = await AppLaunch.open(systemLanguages: ["ru", "fr", "en"]) { _ in
			(kept, keptDefaults)
		}
		guard case .ready(let opened) = launched else {
			Issue.record("The old preference did not reopen after the failed save")
			return
		}
		let reopened = fixture.own(opened)
		#expect(reopened.languagePreference == .fixed(.en))
		#expect(
			reopened.phrasebook.say(Catalog.chatComposerMessagePlaceholder) == "Message your coach")
		try await observed(reopened)
		reopened.draft.text = "How should I pace an easy ride?"
		await reopened.send()
		_ = try await settledTurn(reopened, at: 1)
		#expect(
			kept.fixtureTransport?.lastReplyLanguage?.hasPrefix(
				"The athlete chose English (English).") == true)
	}

	private func openLanguage(_ model: ShellModel, fromSettings: Bool) async {
		if fromSettings {
			model.open(.settings)
			model.openLanguagePicker()
		} else {
			model.draft.text = "/language"
			await model.send()
			#expect(model.draft.text.isEmpty)
		}
	}

	private func frenchInstruction(for preference: LanguagePreference) -> String {
		preference == .automatic
			? "Automatic follows the iPhone's preferred languages. Reply in French (Français)."
			: "The athlete chose French (Français)."
	}

	@Test func sessionSettingsSaveAndSurviveARelaunch() async throws {
		do {
			let services = try services()
			let model = model(services)
			await model.agreeAndStartChatting()
			let stored = try #require(model.status).session
			#expect(stored.text(for: .contextWindowOverride) == "")
			try await model.saveSession(try stored.replacing(.contextWindowOverride, with: "64000"))
			try await model.waitForStatus { $0.session.contextWindowOverride?.tokens == 64_000 }
			#expect(model.status?.session.contextWindowOverride?.tokens == 64_000)
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
			let first = model(try fixtureServices(evening, defaults: defaults))
			await first.agreeAndStartChatting()
			first.draft.text = TutorialCopy.weekQuestion
			await first.send()
			earlier = try await settledTurn(first)
		}
		let (morning, keptDefaults) = try await relaunch(.keep, clock: "1998-06-16T07:00:00Z")
		let second = fixtureModel(
			environment: AppEnvironment(
				services: morning, language: language, defaults: keptDefaults))
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
