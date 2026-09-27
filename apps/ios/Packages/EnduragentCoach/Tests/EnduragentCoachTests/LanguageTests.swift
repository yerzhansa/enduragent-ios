import Foundation
import Synchronization
import Testing

@testable import EnduragentCoach

@Suite struct LanguageTests {
	@Test func registryMatchesSeventeenTagTable() {
		let expected: [(LanguageTag, String, String, String)] = [
			(.en, "English", "English", "en-GB"),
			(.es, "Español", "Spanish", "es-ES"),
			(.fr, "Français", "French", "fr-FR"),
			(.it, "Italiano", "Italian", "it-IT"),
			(.de, "Deutsch", "German", "de-DE"),
			(.nl, "Nederlands", "Dutch", "nl-NL"),
			(.da, "Dansk", "Danish", "da-DK"),
			(.sv, "Svenska", "Swedish", "sv-SE"),
			(.nb, "Norsk bokmål", "Norwegian Bokmål", "nb-NO"),
			(.fi, "Suomi", "Finnish", "fi-FI"),
			(.ptPT, "Português (Portugal)", "Portuguese (Portugal)", "pt-PT"),
			(.ptBR, "Português (Brasil)", "Portuguese (Brazil)", "pt-BR"),
			(.pl, "Polski", "Polish", "pl-PL"),
			(.ko, "한국어", "Korean", "ko-KR"),
			(.ja, "日本語", "Japanese", "ja-JP"),
			(.zhHans, "简体中文", "Simplified Chinese", "zh-Hans-CN"),
			(.zhHant, "繁體中文", "Traditional Chinese", "zh-Hant-TW"),
		]
		#expect(LanguageTag.contractOrder == expected.map(\.0))
		#expect(LanguageTag.allCases.count == 17)
		for (tag, endonym, englishName, locale) in expected {
			#expect(tag.endonym == endonym)
			#expect(tag.englishName == englishName)
			#expect(tag.defaultLocale == locale)
			#expect(LanguageTag(rawValue: tag.rawValue) == tag)
		}
	}

	@Test func resolvePrefersSavedThenMessageThenSurfaceThenEnglish() {
		#expect(
			Language.resolve(saved: .it, messageHint: .fr, surface: .nl)
				== LanguageResolution(language: .it, source: .preference, locale: "it-IT")
		)
		#expect(
			Language.resolve(saved: nil, messageHint: .fr, surface: .nl)
				== LanguageResolution(language: .fr, source: .message, locale: "fr-FR")
		)
		#expect(
			Language.resolve(saved: nil, messageHint: nil, surface: .nl)
				== LanguageResolution(language: .nl, source: .surface, locale: "nl-NL")
		)
		#expect(
			Language.resolve(saved: nil, messageHint: nil, surface: nil)
				== LanguageResolution(language: .en, source: .default, locale: "en-GB")
		)
	}

	@Test func resolveUsesDefaultLocaleOfTheResolvedTag() {
		for tag in LanguageTag.contractOrder {
			let resolved = Language.resolve(saved: tag, messageHint: nil, surface: nil)
			#expect(resolved.locale == tag.defaultLocale)
			#expect(resolved.source == .preference)
		}
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
		let coach = makeCoach(transport: transport, store: store)
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
		let coach = makeCoach(transport: transport, store: InMemoryRecordLog())
		_ = try await coach.sendAndSettle("Come è andata la mia settimana di allenamento oggi?")
		let system = try #require(sent(.chatAttempt, by: transport).first?.messages.first?.content)
		#expect(system.contains("No language is saved."))
		#expect(system.contains("reply in Italian (Italiano)."))
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
		let coach = makeCoach(transport: transport, store: store)
		#expect(await coach.status().language == .fixed(.it))
		_ = try await coach.sendAndSettle("How was my week?")
		let system = try #require(sent(.chatAttempt, by: transport).first?.messages.first?.content)
		#expect(system.contains("The athlete chose Italian (Italiano)."))
		try await coach.setLanguage(.automatic)
		#expect(
			await makeCoach(transport: transport, store: store).status().language == .automatic)
	}

	@Test func statusObservationSeesEachChoice() async throws {
		let coach = makeCoach(transport: FakeModelTransport(), store: InMemoryRecordLog())
		let seen = StatusLog()
		let stream = await coach.observeStatus()
		let watching = Task {
			for await status in stream {
				seen.append(status)
			}
		}
		defer { watching.cancel() }
		try await coach.setLanguage(.fixed(.ja))
		let hour = try SessionSettings.npmDefaults.replacing(.dailyResetHour, with: "6")
		try await coach.setSession(hour)
		let statuses = try await seen.first(3)
		#expect(statuses.map(\.language) == [.automatic, .fixed(.ja), .fixed(.ja)])
		#expect(statuses.map(\.session) == [.npmDefaults, .npmDefaults, hour])
	}

	@Test func overlappingChoicesSettleOnTheLatestRecord() async throws {
		let store = InMemoryRecordLog()
		let held = HeldAppendLog(inner: store, holding: "languagePreference", occurrence: 1)
		let coach = makeCoach(transport: FakeModelTransport(), store: held)
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

	@Test func failedWriteKeepsThePreviousPreference() async throws {
		let log = FaultInjectingRecordLog(wrapping: InMemoryRecordLog())
		let coach = makeCoach(transport: FakeModelTransport(), store: log)
		try await coach.setLanguage(.fixed(.de))
		log.failAppends(ofKind: SyncedKind.languagePreference)
		await #expect(throws: PreferenceWriteFailure.notSaved) {
			try await coach.setLanguage(.fixed(.fr))
		}
		#expect(await coach.status().language == .fixed(.de))
	}

	@Test func writeResolveEvidenceWhenPresent() throws {
		let directory = URL(fileURLWithPath: "/tmp/ios-c7")
		guard FileManager.default.fileExists(atPath: directory.path) else { return }
		var detect: [[String: String]] = []
		for language in LanguageTag.contractOrder {
			for message in DetectFixtures.messages[language] ?? [] {
				let found = Language.detectMessageLanguage(message)?.rawValue ?? ""
				detect.append(["input": message, "output": found, "expected": language.rawValue])
			}
		}
		for sample in ["", "ok", "/review", "the und et", "bonjour"] {
			detect.append([
				"input": sample, "output": Language.detectMessageLanguage(sample)?.rawValue ?? "",
			])
		}
		var normalize: [[String: String]] = []
		for hint in ["it_IT.UTF-8", "C", "pt-br", "pt", "zh-TW", "no", "nn", "ru_RU:fr_FR:en"] {
			normalize.append([
				"input": hint, "output": Language.normalizeLocaleHint(hint)?.rawValue ?? "",
			])
		}
		var resolve: [[String: String]] = []
		for saved in [Optional<LanguageTag>.none, .it] {
			for message in [Optional<LanguageTag>.none, .fr] {
				for surface in [Optional<LanguageTag>.none, .nl] {
					let result = Language.resolve(
						saved: saved, messageHint: message, surface: surface)
					resolve.append([
						"saved": saved?.rawValue ?? "",
						"message": message?.rawValue ?? "",
						"surface": surface?.rawValue ?? "",
						"language": result.language.rawValue,
						"source": result.source.rawValue,
						"locale": result.locale,
					])
				}
			}
		}
		let payload: [String: Any] = ["detect": detect, "normalize": normalize, "resolve": resolve]
		let data = try JSONSerialization.data(
			withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
		try data.write(to: directory.appendingPathComponent("resolve-swift.json"))
	}
}

private final class StatusLog: Sendable {
	private let statuses = Mutex<[CoachStatus]>([])

	func append(_ status: CoachStatus) {
		statuses.withLock { $0.append(status) }
	}

	func first(_ count: Int, within limit: Duration = .seconds(5)) async throws -> [CoachStatus] {
		let deadline = ContinuousClock.now + limit
		while statuses.withLock({ $0.count }) < count, ContinuousClock.now < deadline {
			try await Task.sleep(for: .milliseconds(10))
		}
		return statuses.withLock { Array($0.prefix(count)) }
	}
}
