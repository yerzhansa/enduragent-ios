import EnduragentCoach
import Foundation
import Testing

@testable import Enduragent

extension FixtureLaunchTests {
	@Test(arguments: [
		(
			LanguagePreference.fixed(.fr), ["en-US"], Optional<String>.none, LanguageTag.fr,
			"Écris à ton coach"
		),
		(.fixed(.fr), ["en-US"], "de", .fr, "Écris à ton coach"),
		(.fixed(.fr), ["en-US"], "invalid", .fr, "Écris à ton coach"),
		(.automatic, ["ru-RU", "fr-FR", "en-US"], nil, .fr, "Écris à ton coach"),
		(.automatic, ["ru-RU", "fr-FR"], nil, .fr, "Écris à ton coach"),
		(.automatic, ["ru-RU", "ar"], nil, .en, "Message your coach"),
		(.automatic, ["ru-RU", "ar"], "fr", .en, "Message your coach"),
		(.automatic, ["ru-RU", "ar"], "invalid", .en, "Message your coach"),
		(.automatic, ["pt-BR", "pt-PT"], nil, .ptBR, "Envie uma mensagem ao seu treinador"),
		(.automatic, ["zh-Hant", "zh-Hans"], nil, .zhHant, "傳送訊息給教練"),
	])
	func preferredListAndIgnoredOverrideReachTheShellAndCoach(
		preference: LanguagePreference, preferredLanguages: [String], override: String?,
		expected: LanguageTag, placeholder: String
	) async throws {
		let name = "ENDURAGENT_LANGUAGE"
		let previous = getenv(name).map { String(cString: $0) }
		defer {
			let restored = previous.map { setenv(name, $0, 1) } ?? unsetenv(name)
			#expect(restored == 0)
		}
		try #require((override.map { setenv(name, $0, 1) } ?? unsetenv(name)) == 0)
		try #require(ProcessInfo.processInfo.environment[name] == override)
		try await services().coach.setLanguage(preference)
		let launched = await AppLaunch.open(
			displayLocale: testLocaleResolver(languages: preferredLanguages)
		) { displayLocale in
			(
				try fixtureServices(launch, defaults: defaults, displayLocale: displayLocale),
				defaults
			)
		}
		guard case .ready(let opened) = launched else {
			Issue.record("The language preference did not reopen into a ready shell")
			return
		}
		let model = fixture.own(opened)
		#expect(model.route == .onboarding(.notice))
		#expect(model.languagePreference == preference)
		#expect(model.phrasebook.tag == expected)
		#expect(model.phrasebook.say(Catalog.chatComposerMessagePlaceholder) == placeholder)
		await model.agreeAndStartChatting()
		try await observed(model)
		model.draft.text = "How was my training week?"
		await model.send()
		_ = try await settledTurn(model)
		#expect(model.phrasebook.say(Catalog.chatComposerMessagePlaceholder) == placeholder)
		let instruction = try #require(model.services.fixtureTransport?.lastReplyLanguage)
		#expect(
			instruction.contains(
				"Write every athlete-facing sentence in \(expected.englishName), even when the athlete writes in another language."
			))
		#expect(instruction.hasPrefix("Reply in \(expected.englishName) (\(expected.endonym))."))
	}
}
