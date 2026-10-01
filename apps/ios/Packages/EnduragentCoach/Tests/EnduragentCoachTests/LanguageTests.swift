import Foundation
import Testing

@testable import EnduragentCoach

@Suite struct LanguageTests {
	@Test func registryMatchesSeventeenTagTable() {
		let expected: [(LanguageTag, String, String)] = [
			(.en, "English", "English"),
			(.es, "Español", "Spanish"),
			(.fr, "Français", "French"),
			(.it, "Italiano", "Italian"),
			(.de, "Deutsch", "German"),
			(.nl, "Nederlands", "Dutch"),
			(.da, "Dansk", "Danish"),
			(.sv, "Svenska", "Swedish"),
			(.nb, "Norsk bokmål", "Norwegian Bokmål"),
			(.fi, "Suomi", "Finnish"),
			(.ptPT, "Português (Portugal)", "Portuguese (Portugal)"),
			(.ptBR, "Português (Brasil)", "Portuguese (Brazil)"),
			(.pl, "Polski", "Polish"),
			(.ko, "한국어", "Korean"),
			(.ja, "日本語", "Japanese"),
			(.zhHans, "简体中文", "Simplified Chinese"),
			(.zhHant, "繁體中文", "Traditional Chinese"),
		]
		#expect(LanguageTag.contractOrder == expected.map(\.0))
		#expect(LanguageTag.allCases.count == 17)
		for (tag, endonym, englishName) in expected {
			#expect(tag.endonym == endonym)
			#expect(tag.englishName == englishName)
			#expect(LanguageTag(rawValue: tag.rawValue) == tag)
		}
	}

	@Test func replyLanguageKeepsFixedAndMirrorDistinct() {
		let message = "Comment était ma semaine et que dois-je faire aujourd'hui ?"
		#expect(
			LanguagePreference.fixed(.it).replyLanguage(for: message, device: .nl) == .fixed(.it))
		#expect(
			LanguagePreference.automatic.replyLanguage(for: message, device: .nl)
				== .mirror(fallback: .fr))
		#expect(
			LanguagePreference.automatic.replyLanguage(for: "123", device: .nl)
				== .mirror(fallback: .nl))
	}

	@Test func normalizeLocaleHintMatchesDesktop() {
		let cases: [(String, LanguageTag?)] = [
			("it_IT.UTF-8", .it),
			("C", nil),
			("C.UTF-8", nil),
			("POSIX", nil),
			("pt-br", .ptBR),
			("nl-BE", .nl),
			("fr-BE", .fr),
			("de-BE", .de),
			("pt", .ptPT),
			("zh", .zhHans),
			("zh-TW", .zhHant),
			("zh-HK", .zhHant),
			("zh-CN", .zhHans),
			("zh-SG", .zhHans),
			("zh-Hans-TW", .zhHans),
			("zh-Hant-CN", .zhHant),
			("no", .nb),
			("nn", .nb),
			("en_US:en", .en),
			("ru_RU:fr_FR:en", .fr),
			("it_IT.UTF-8@euro", .it),
			("xx", nil),
			("", nil),
		]
		for (hint, expected) in cases {
			#expect(Language.normalizeLocaleHint(hint) == expected)
		}
		#expect(Language.normalizeLocaleHint(["ru", "fr-BE", "it"]) == .fr)
		#expect(Language.normalizeLocaleHint(["C:xx", "pt-br:en"]) == .ptBR)
		#expect(Language.normalizeLocaleHint([String]()) == nil)
		for tag in LanguageTag.contractOrder {
			#expect(Language.normalizeLocaleHint(tag.rawValue) == tag)
		}
	}

	@Test func uiTagUsesFirstSupportedSystemLanguageElseEnglish() {
		#expect(Language.uiTag(systemLanguages: ["it-IT", "en-US"]) == .it)
		#expect(Language.uiTag(systemLanguages: ["pt-BR"]) == .ptBR)
		#expect(Language.uiTag(systemLanguages: ["pt"]) == .ptPT)
		#expect(Language.uiTag(systemLanguages: ["zh-Hant-TW"]) == .zhHant)
		#expect(Language.uiTag(systemLanguages: ["ru-RU", "ja-JP"]) == .ja)
		#expect(Language.uiTag(systemLanguages: ["C", "xx"]) == .en)
		#expect(Language.uiTag(systemLanguages: []) == .en)
	}

	@Test func languageSlashYieldsLanguageCommandAndStartsNoModelTurn() {
		#expect(SlashRouting.parse("/language") == .language)
		#expect(SlashRouting.parse("  /language  ") == .language)
		#expect(SlashRouting.parse("/language it") == .language)
		#expect(SlashCommand.language.route == .languagePicker)
		#expect(SlashRouting.parse("/review") != .language)
	}

	@Test func fixedPreferenceChangesAppTextAndReplySection() async throws {
		let transport = FakeModelTransport()
		transport.script = [
			.text("Two rides."), .finish(reason: .stop), .text("Deux sorties."),
			.finish(reason: .stop),
		]
		let store = InMemoryRecordLog()
		let coach = await makeCoach(transport: transport, store: store)
		let automatic = await coach.status().language
		#expect(automatic == .automatic)
		#expect(automatic.phrasebook(device: .en).say(Catalog.chatViewTitle) == "Chat")
		_ = try await coach.sendAndSettle("How was my week?")
		try await coach.setLanguage(.fixed(.fr))
		let chosen = await coach.status().language
		#expect(chosen == .fixed(.fr))
		let french = chosen.phrasebook(device: .en)
		#expect(french.say(Catalog.chatViewTitle) == "Conversation")
		#expect(french.say(Catalog.chatComposerMessagePlaceholder) == "Écris à ton coach")
		#expect(
			french.say(Catalog.coachConfirmationExpired)
				== "Cette proposition a expiré — redemande-moi et je te la proposerai à nouveau.")
		#expect(
			french.say(Catalog.coachConfirmationExecuted, ["summary": "Endurance"])
				== "C’est fait — Endurance.")
		_ = try await coach.sendAndSettle("How was my week?")
		let systems = sent(.chatAttempt, by: transport).compactMap { $0.messages.first?.content }
		try #require(systems.count == 2)
		#expect(systems[0].contains("No language is saved."))
		#expect(systems[0].contains("reply in English (English)."))
		#expect(systems[1].contains("The athlete chose French (Français)."))
		#expect(
			await makeCoach(transport: FakeModelTransport(), store: store).status().language
				== .fixed(.fr))
		#expect(
			try await store.fetch(RecordQuery(scope: .synced([.languagePreference]))).records
				.count == 1)
	}

	@Test func automaticPreferenceRepliesInTheMessageLanguage() async throws {
		let transport = FakeModelTransport()
		transport.script = [.text("Bene."), .finish(reason: .stop)]
		let coach = await makeCoach(transport: transport, store: InMemoryRecordLog())
		_ = try await coach.sendAndSettle("Come è andata la mia settimana di allenamento oggi?")
		let system = try #require(sent(.chatAttempt, by: transport).first?.messages.first?.content)
		#expect(system.contains("No language is saved."))
		#expect(system.contains("reply in Italian (Italiano)."))
	}

	@Test func automaticRepliesFollowEachMessageWithTheInterfaceLanguageFallback() async throws {
		let transport = FakeModelTransport()
		let coach = await makeCoach(
			transport: transport, store: InMemoryRecordLog(), deviceLanguage: .fr)
		let messages: [(String, LanguageTag)] = [
			("Come è andata la mia settimana di allenamento oggi?", .it),
			("How was my training week and what should I do today?", .en),
			("123", .fr),
		]
		for (message, language) in messages {
			transport.script = [.text("Reply"), .finish(reason: .stop)]
			_ = try await coach.sendAndSettle(message)
			let system = try #require(
				sent(.chatAttempt, by: transport).last?.messages.first?.content)
			#expect(system.contains("No language is saved."))
			#expect(system.contains("Reply in the language of the athlete's latest message"))
			#expect(system.contains("reply in \(language.englishName) (\(language.endonym))."))
		}
	}

	@Test(arguments: [LanguageTag.es, .fr])
	func automaticAppTextFollowsANonEnglishPhone(device: LanguageTag) async {
		let coach = await makeCoach(
			transport: FakeModelTransport(), store: InMemoryRecordLog(), deviceLanguage: device)
		let preference = await coach.status().language
		#expect(preference == .automatic)
		#expect(
			preference.phrasebook(device: device).say(Catalog.chatComposerMessagePlaceholder)
				== device.phrasebook.say(Catalog.chatComposerMessagePlaceholder))
	}

	@Test func legacyCoachReplyLanguageFoldsOnlyWithoutPreference() async throws {
		let device = DeviceID(rawValue: "phone-a")
		let italian = storedRecord(
			device: device, wall: 2,
			body: .synced(.coachReplyLanguage(CoachReplyLanguageBody(tag: .it))))
		let cleared = storedRecord(
			device: device, wall: 3,
			body: .synced(.coachReplyLanguage(CoachReplyLanguageBody(tag: nil))))
		let chosenEarlier = storedRecord(
			device: device, wall: 1,
			body: .synced(.languagePreference(LanguagePreferenceBody(preference: .automatic))))
		#expect(Preferences.fold([]).language == .automatic)
		#expect(Preferences.fold([italian]).language == .fixed(.it))
		#expect(Preferences.fold([italian, cleared]).language == .automatic)
		#expect(Preferences.fold([italian, chosenEarlier]).language == .automatic)
		let store = InMemoryRecordLog()
		try await seed(store, [italian])
		let transport = FakeModelTransport()
		transport.script = [.text("Due uscite."), .finish(reason: .stop)]
		let coach = await makeCoach(transport: transport, store: store)
		#expect(await coach.status().language == .fixed(.it))
		_ = try await coach.sendAndSettle("How was my week?")
		let system = try #require(sent(.chatAttempt, by: transport).first?.messages.first?.content)
		#expect(system.contains("The athlete chose Italian (Italiano)."))
		try await coach.setLanguage(.automatic)
		#expect(
			await makeCoach(transport: transport, store: store).status().language == .automatic)
	}

	@Test func statusCarriesEachChoice() async throws {
		let coach = await makeCoach(transport: FakeModelTransport(), store: InMemoryRecordLog())
		#expect(await coach.status().language == .automatic)
		try await coach.setLanguage(.fixed(.ja))
		#expect(await coach.status().language == .fixed(.ja))
		let ratio = try SessionSettings.npmDefaults.replacing(.historyBudgetRatio, with: "0.05")
		try await coach.setSession(ratio)
		let status = await coach.status()
		#expect(status.session == ratio)
		#expect(status.language == .fixed(.ja))
		#expect(status.setup == .ready)
	}

	@Test func overlappingChoicesSettleOnTheLatestRecord() async throws {
		let store = InMemoryRecordLog()
		let held = HeldAppendLog(inner: store, holding: "languagePreference", occurrence: 1)
		let coach = await makeCoach(transport: FakeModelTransport(), store: held)
		#expect(await coach.status().language == .automatic)
		let first = Task { try await coach.setLanguage(.fixed(.fr)) }
		var reached = held.reached.makeAsyncIterator()
		await reached.next()
		try await coach.setLanguage(.fixed(.de))
		held.release()
		try await first.value
		let stored = await makeCoach(transport: FakeModelTransport(), store: store).status()
		#expect(stored.language == .fixed(.de))
		#expect(await coach.status().language == .fixed(.de))
	}

	@Test func leaseTitlesFollowTheAppLanguage() async throws {
		let host = ImmediateExecutionHost()
		let transport = FakeModelTransport()
		transport.script = [
			.text("Dos salidas."), .finish(reason: .stop), .text("Two rides."),
			.finish(reason: .stop),
		]
		let coach = await makeCoach(transport: transport, store: InMemoryRecordLog(), host: host)
		try await coach.setLanguage(.fixed(.es))
		_ = try await coach.sendAndSettle("How was my week?")
		let spanish = try #require(await host.ended(0))
		#expect(spanish.request.language == .es)
		#expect(spanish.request.titleText == "El entrenador está trabajando…")
		guard case .finished(let notice?) = spanish.ending else {
			Issue.record("the lease ended without a notice: \(String(describing: spanish.ending))")
			return
		}
		#expect(notice.titleText == "Entrenador")
		#expect(notice.excerpt == "Dos salidas.")
		try await coach.setLanguage(.automatic)
		_ = try await coach.sendAndSettle("And this week?")
		let automatic = try #require(await host.ended(1))
		#expect(automatic.request.language == .en)
		#expect(automatic.request.titleText == "Coach is working…")
	}

	@Test func completionTitleFollowsAChoiceMadeDuringTheReply() async throws {
		let host = ImmediateExecutionHost()
		let transport = FakeModelTransport()
		transport.script = [.text("One more ride."), .finish(reason: .stop)]
		let store = HeldAppendLog(inner: InMemoryRecordLog(), holding: "turnSettled", occurrence: 1)
		let coach = await makeCoach(transport: transport, store: store, host: host)
		let turn = try #require(
			try await coach.send(draft("How was my week?"), to: .main).acceptedTurn)
		var reached = store.reached.makeAsyncIterator()
		await reached.next()
		try await coach.setLanguage(.fixed(.es))
		#expect(await coach.status().language == .fixed(.es))
		store.release()
		_ = try #require(await coach.settledState(of: turn, in: .main))
		let ended = try #require(await host.ended(0))
		#expect(ended.request.titleText == "Coach is working…")
		guard case .finished(let notice?) = ended.ending else {
			Issue.record("Missing completion notice")
			return
		}
		#expect(notice.titleText == "Entrenador")
		#expect(notice.excerpt == "One more ride.")
	}

	@Test func choosingTheCurrentLanguageWritesNothing() async throws {
		let store = InMemoryRecordLog()
		let coach = await makeCoach(transport: FakeModelTransport(), store: store)
		try await coach.setLanguage(.automatic)
		try await coach.setLanguage(.fixed(.fr))
		try await coach.setLanguage(.fixed(.fr))
		#expect(
			try await store.fetch(RecordQuery(scope: .synced([.languagePreference]))).records
				.count == 1)
		#expect(await coach.status().language == .fixed(.fr))
	}

	@Test func failedWriteKeepsThePreviousPreference() async throws {
		let log = FaultInjectingRecordLog(wrapping: InMemoryRecordLog())
		let coach = await makeCoach(transport: FakeModelTransport(), store: log)
		try await coach.setLanguage(.fixed(.de))
		try log.failAppends(ofKind: "languagePreference")
		await #expect(throws: PreferenceWriteFailure.notSaved) {
			try await coach.setLanguage(.fixed(.fr))
		}
		#expect(await coach.status().language == .fixed(.de))
	}
}
