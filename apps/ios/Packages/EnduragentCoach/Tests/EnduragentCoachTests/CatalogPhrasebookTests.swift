import Foundation
import Testing

@testable import EnduragentCoach

@Suite struct CatalogPhrasebookTests {
	@Test func catalogCountsMatchTheGenerator() {
		#expect(Catalog.englishLeafCount == 2431)
		#expect(Catalog.keyCount == 2467)
	}

	@Test(arguments: [
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
	])
	func newKeysRenderInEnglishAndFallBackForOtherTags(key: CatalogKey, english: String) {
		#expect(CatalogPhrasebook(tag: .en, locale: "en-US").say(key) == english)
		for tag in LanguageTag.allCases where tag != .en {
			#expect(CatalogPhrasebook(tag: tag, locale: tag.defaultLocale).say(key) == english)
		}
	}

	@Test func italianCancelUsesTheItalianCatalog() {
		let book = CatalogPhrasebook(tag: .it, locale: "it-IT")
		#expect(book.say(Catalog.commonCancel) == "Annulla")
	}

	@Test func polishCountThreeSelectsTheFewForm() {
		let book = CatalogPhrasebook(tag: .pl, locale: "pl-PL")
		#expect(
			book.say(Catalog.archiveTurnCount, ["count": "3", "formattedCount": "3"])
				== "3 wiadomości")
		#expect(
			book.say(Catalog.trainingViewRideCount, ["count": "3", "number": "3"]) == "3 przejazdy")
		#expect(
			book.say(Catalog.trainingViewRideCount, ["count": "1", "number": "1"]) == "1 przejazd")
		#expect(
			book.say(Catalog.trainingViewRideCount, ["count": "5", "number": "5"]) == "5 przejazdów"
		)
	}

	@Test func japanesePluralsUseOtherOnly() {
		let book = CatalogPhrasebook(tag: .ja, locale: "ja-JP")
		#expect(
			book.say(Catalog.archiveTurnCount, ["count": "1", "formattedCount": "1"]) == "1件のメッセージ")
		#expect(
			book.say(Catalog.archiveTurnCount, ["count": "3", "formattedCount": "3"]) == "3件のメッセージ")
	}

	@Test func brazilianPortugueseDoesNotFallBackToPortugal() {
		let brazilian = CatalogPhrasebook(tag: .ptBR, locale: "pt-PT")
		let portugal = CatalogPhrasebook(tag: .ptPT, locale: "pt-BR")
		#expect(brazilian.say(Catalog.archiveAthlete) == "Você")
		#expect(portugal.say(Catalog.archiveAthlete) == "Tu")
		#expect(brazilian.say(Catalog.archiveAthlete) != portugal.say(Catalog.archiveAthlete))
	}

	@Test func missingKeyReturnsEnglishNeverTheRawKey() {
		let book = CatalogPhrasebook(tag: .it, locale: "it-IT")
		#expect(book.say(Catalog.commonCancel) != Catalog.commonCancel.rawValue)
		let missing = CatalogKey(rawValue: "not.a.catalog.key")
		let value = book.say(missing)
		#expect(value != missing.rawValue)
		#expect(value == CatalogPhrasebook(tag: .en, locale: "en-GB").say(missing))
	}

	@Test func namedSubstitutionDoesNotEscapeValues() {
		let book = CatalogPhrasebook(tag: .en, locale: "en-GB")
		#expect(book.say(Catalog.trainingPowerPercent, ["value": "42"]) == "42%")
	}
}
