import Testing

@testable import EnduragentCoach

@Suite struct CatalogPhrasebookTests {
	@Test func missingVariableStaysVisible() {
		#expect(LanguageTag.en.phrasebook.say(Catalog.trainingPowerPercent) == "%#@value@%")
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

	@Test(arguments: LanguageTag.allCases.filter { $0 != .en })
	func reviewCopyUsesEverySelectedLanguage(_ tag: LanguageTag) {
		let book = tag.phrasebook
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
