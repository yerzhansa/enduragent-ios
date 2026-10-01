import Foundation
import Testing

@testable import EnduragentCoach

@Suite struct CatalogPhrasebookTests {
	@Test func missingVariableStaysVisible() {
		#expect(LanguageTag.en.phrasebook.say(Catalog.trainingPowerPercent) == "%#@value@%")
	}

	@Test func catalogCountsMatchTheGenerator() {
		#expect(Catalog.englishLeafCount == 2473)
		#expect(Catalog.keyCount == 2513)
	}

	@Test func connectPlaceholderStaysTheEnglishApiKeyLabel() {
		let book = CatalogPhrasebook(tag: .en)
		#expect(book.say(Catalog.onboardingConnectApiKey) == "intervals.icu API key")
		#expect(
			book.say(Catalog.creditsBalance, count: 1, ["formattedCount": "1"]) == "1 credit")
		#expect(
			book.say(Catalog.creditsBalance, count: 12, ["formattedCount": "12"])
				== "12 credits")
	}

	@Test(arguments: [
		(LanguageTag.en, "New conversation"),
		(LanguageTag.da, "Ny samtale"),
		(LanguageTag.de, "Neues Gespräch"),
		(LanguageTag.es, "Nueva conversación"),
		(LanguageTag.fi, "Uusi keskustelu"),
		(LanguageTag.fr, "Nouvelle conversation"),
		(LanguageTag.it, "Nuova conversazione"),
		(LanguageTag.ja, "新しい会話"),
		(LanguageTag.ko, "새 대화"),
		(LanguageTag.nb, "Ny samtale"),
		(LanguageTag.nl, "Nieuw gesprek"),
		(LanguageTag.pl, "Nowa rozmowa"),
		(LanguageTag.ptBR, "Nova conversa"),
		(LanguageTag.ptPT, "Nova conversa"),
		(LanguageTag.sv, "Nytt samtal"),
		(LanguageTag.zhHans, "新对话"),
		(LanguageTag.zhHant, "新對話"),
	])
	func newConversationLabelUsesEverySelectedLanguage(tag: LanguageTag, expected: String) {
		let book = LanguagePreference.fixed(tag).phrasebook(device: .en)
		#expect(book.say(Catalog.chatNewConversationLabel) == expected)
	}

	@Test(arguments: [
		(Catalog.archiveReasonEarlierChat, "Earlier chat"),
		(
			Catalog.creditsErrorAccessRejected,
			"Your Credits couldn't be used. Restore purchases to continue."
		),
		(
			Catalog.creditsErrorExhausted,
			"You're out of Credits. Buy more, or switch to your OpenRouter account."
		),
		(
			Catalog.accessErrorOpenRouterFunds,
			"Your OpenRouter account is out of funds. Add funds on OpenRouter, or switch to Credits."
		),
		(Catalog.accessErrorLocked, "Unlock your iPhone to continue. Your message is saved."),
		(Catalog.accessErrorNotConfigured, "Choose how the coach reaches a model to continue."),
		(Catalog.connectErrorRejected, "intervals.icu did not accept that key."),
		(Catalog.creditsErrorUnavailable, "Credits are unavailable right now. Try again later."),
		(
			Catalog.chatTurnInterruptedNothingChanged,
			"This reply stopped before it finished. Nothing was changed."
		),
		(
			Catalog.chatTurnInterruptedSomeSaved,
			"This reply stopped before it finished. Some information was saved first."
		),
		(
			Catalog.chatNoticeSavedUnverified,
			"I saved your information, but couldn't verify my response. Please try again."
		),
		(Catalog.chatTurnBuyCredits, "Buy Credits"),
		(Catalog.chatTurnRestorePurchases, "Restore purchases"),
		(Catalog.chatTurnChooseAccessMethod, "Choose access method"),
		(Catalog.chatTurnSignInAgain, "Sign in again"),
		(Catalog.chatTurnFinishedWhileLocked, "Finished while the phone was locked."),
	])
	func newKeysRenderInEnglishAndEverySelectedLanguage(key: CatalogKey, english: String) {
		#expect(CatalogPhrasebook(tag: .en).say(key) == english)
		for tag in LanguageTag.allCases where tag != .en {
			let localized = CatalogPhrasebook(tag: tag).say(key)
			#expect(!localized.isEmpty)
			#expect(localized != english)
		}
	}

	@Test func germanRecoveryCopyUsesTranslatedCatalog() {
		let book = LanguageTag.de.phrasebook
		#expect(book.say(Catalog.chatTurnBuyCredits) == "Guthaben kaufen")
		#expect(
			book.say(Catalog.accessErrorLocked)
				== "Entsperre dein iPhone, um fortzufahren. Deine Nachricht ist gespeichert.")
	}

	@Test(arguments: LanguageTag.allCases)
	func menuUsesEverySelectedLanguage(_ tag: LanguageTag) throws {
		let translations: [LanguageTag: String] = [
			.en: "Menu",
			.es: "Menú",
			.fr: "Menu",
			.it: "Menu",
			.de: "Menü",
			.nl: "Menu",
			.da: "Menu",
			.sv: "Meny",
			.nb: "Meny",
			.fi: "Valikko",
			.ptPT: "Menu",
			.ptBR: "Menu",
			.pl: "Menu",
			.ko: "메뉴",
			.ja: "メニュー",
			.zhHans: "菜单",
			.zhHant: "選單",
		]
		let expected = try #require(translations[tag])
		let book = LanguagePreference.fixed(tag).phrasebook(device: .en)
		#expect(book.say(Catalog.chatMenu) == expected)
	}

	@Test(arguments: LanguageTag.allCases.filter { $0 != .en })
	func reviewCopyUsesEverySelectedLanguage(_ tag: LanguageTag) {
		let book = LanguagePreference.fixed(tag).phrasebook(device: .en)
		let english = CatalogPhrasebook(tag: .en)
		for key in [
			Catalog.reviewTitle, Catalog.reviewAdd, Catalog.reviewAccountChanged,
			Catalog.reviewCannotVerify, Catalog.reviewUncertain, Catalog.reviewEarlierVersion,
		] {
			let copy = book.say(key, ["service": "intervals.icu"])
			#expect(copy != english.say(key, ["service": "intervals.icu"]))
			#expect(!copy.contains("{{"))
			#expect(!copy.contains("%#@"))
		}
	}

	@Test func italianCancelUsesTheItalianCatalog() {
		let book = CatalogPhrasebook(tag: .it)
		#expect(book.say(Catalog.commonCancel) == "Annulla")
	}

	@Test func frenchConfirmationUsesTheFrenchCatalog() {
		let book = CatalogPhrasebook(tag: .fr)
		#expect(
			book.say(Catalog.coachConfirmationExpired)
				== "Cette proposition a expiré — redemande-moi et je te la proposerai à nouveau.")
		#expect(
			book.say(Catalog.coachConfirmationExecuted, ["summary": "Endurance"])
				== "C’est fait — Endurance.")
	}

	@Test func polishCountThreeSelectsTheFewForm() {
		let book = CatalogPhrasebook(tag: .pl)
		#expect(
			book.say(Catalog.archiveTurnCount, count: 3, ["formattedCount": "3"])
				== "3 wiadomości")
		#expect(
			book.say(Catalog.trainingViewRideCount, count: 3, ["number": "3"]) == "3 przejazdy")
		#expect(
			book.say(Catalog.trainingViewRideCount, count: 1, ["number": "1"]) == "1 przejazd")
		#expect(
			book.say(Catalog.trainingViewRideCount, count: 5, ["number": "5"]) == "5 przejazdów"
		)
	}

	@Test func japanesePluralsUseOtherOnly() {
		let book = CatalogPhrasebook(tag: .ja)
		#expect(
			book.say(Catalog.archiveTurnCount, count: 1, ["formattedCount": "1"]) == "1件のメッセージ")
		#expect(
			book.say(Catalog.archiveTurnCount, count: 3, ["formattedCount": "3"]) == "3件のメッセージ")
	}

	@Test func brazilianPortugueseDoesNotFallBackToPortugal() {
		let brazilian = CatalogPhrasebook(tag: .ptBR)
		let portugal = CatalogPhrasebook(tag: .ptPT)
		#expect(brazilian.say(Catalog.archiveAthlete) == "Você")
		#expect(portugal.say(Catalog.archiveAthlete) == "Tu")
		#expect(brazilian.say(Catalog.archiveAthlete) != portugal.say(Catalog.archiveAthlete))
	}

	@Test func missingKeyReturnsEnglishNeverTheRawKey() {
		let book = CatalogPhrasebook(tag: .it)
		#expect(book.say(Catalog.commonCancel) != Catalog.commonCancel.rawValue)
		let missing = CatalogKey(rawValue: "not.a.catalog.key")
		let value = book.say(missing)
		#expect(value != missing.rawValue)
		#expect(value == CatalogPhrasebook(tag: .en).say(missing))
	}

	@Test func namedSubstitutionDoesNotEscapeValues() {
		let book = CatalogPhrasebook(tag: .en)
		#expect(book.say(Catalog.trainingPowerPercent, ["value": "42"]) == "42%")
	}
}
