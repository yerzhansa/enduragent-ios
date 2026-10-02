import Foundation
import Testing

@testable import EnduragentCoach

@Suite struct CatalogCompletenessTests {
	@Test(arguments: LanguageTag.allCases)
	func everyEnglishKeyHasAValueInEveryLocale(_ tag: LanguageTag) throws {
		let english = try leaves(in: catalogs.appending(path: "en.json"))
		let localized = try leaves(in: catalogs.appending(path: "\(tag.rawValue).json"))
		let exceptions = try sharedValues(for: tag.rawValue)
		#expect(LanguageTag.allCases.count == 17)
		for issue in issues(
			english: english, localized: localized, tag: tag.rawValue, exceptions: exceptions)
		{
			Issue.record(Comment(rawValue: issue))
		}
	}

	@Test(arguments: LanguageTag.allCases)
	func cancellationAndReadFailureAreTranslated(_ tag: LanguageTag) throws {
		let english = try leaves(in: catalogs.appending(path: "en.json"))
		let localized = try leaves(in: catalogs.appending(path: "\(tag.rawValue).json"))
		for key in ["review.cancelledUnknown", "review.storageUnavailable", "review.saveFailed"] {
			let text = try #require(localized[key])
			#expect(!text.isEmpty)
			if tag != .en { #expect(text != english[key]) }
		}
		#expect(english["review.cancelledUnknown"] == CancelUnknownSaveTests.sentence)
		#expect(
			english["review.storageUnavailable"]
				== "Couldn't read the saved workout review. Its buttons are temporarily disabled.")
		#expect(
			english["review.saveFailed"]
				== "Couldn't save your choice on this iPhone, so nothing was changed. Try again.")
	}

	@Test(arguments: ["", " \n\t"])
	func emptyTranslationsAreRejected(_ value: String) {
		#expect(
			issues(english: ["message": "Hello"], localized: ["message": value], tag: "de") == [
				"de has an empty value for message"
			])
	}

	@Test func copiedEnglishIsRejected() {
		#expect(
			issues(
				english: ["message": "Try again."], localized: ["message": "Try again."], tag: "de")
				== ["de copies English for message"])
	}

	@Test(arguments: ["extra", "message_bogus", "message_few"])
	func keysOutsideEnglishAreRejected(_ key: String) {
		#expect(
			issues(
				english: ["message": "Hello"], localized: ["message": "Hallo", key: "Zusatz"],
				tag: "de") == ["de has an unexpected key \(key)"])
	}

	@Test func polishPluralVariantsRequireAnEnglishPluralFamily() {
		let english = ["message_other": "Messages"]
		#expect(
			issues(
				english: english,
				localized: [
					"message_other": "Wiadomości", "message_few": "Wiadomości",
					"message_many": "Wiadomości",
				], tag: "pl"
			).isEmpty)
		#expect(
			issues(
				english: english,
				localized: ["message_other": "Wiadomości", "extra_few": "Dodatki"], tag: "pl") == [
					"pl has an unexpected key extra_few"
				])
	}

	@Test(arguments: ["ja", "ko", "zh-Hans", "zh-Hant"])
	func languagesWithoutSingularPluralsOnlyNeedOther(_ tag: String) {
		#expect(
			issues(
				english: ["message_one": "Message", "message_other": "Messages"],
				localized: ["message_other": "訳"], tag: tag
			).isEmpty)
	}

	@Test func sharedValuesAreLimitedToTheirReviewedKeyAndValue() {
		let english = ["title": "Coach"]
		#expect(
			issues(english: english, localized: english, tag: "de", exceptions: ["title": "Coach"])
				.isEmpty)
		#expect(
			issues(
				english: english, localized: english, tag: "de", exceptions: ["another": "Coach"])
				== ["de copies English for title"])
		#expect(
			issues(
				english: english, localized: english, tag: "de", exceptions: ["title": "Training"])
				== ["de copies English for title"])
	}

	@Test(arguments: LanguageTag.allCases)
	func changedPlaceholdersAreRejected(_ tag: LanguageTag) {
		for value in ["Bonjour {{renamed}}", "Bonjour", "Bonjour {{name}} {{extra}}"] {
			#expect(
				issues(
					english: ["message": "Hello {{name}}"], localized: ["message": value],
					tag: tag.rawValue) == ["\(tag.rawValue) has different placeholders for message"]
			)
		}
	}

	@Test(arguments: ["one", "other", "few", "many"])
	func pluralPlaceholdersMatchTheEnglishFamily(_ form: String) {
		let english = ["message_one": "Hello {{name}}", "message_other": "Greetings {{name}}"]
		let key = "message_\(form)"
		var localized = ["message_one": "Cześć {{name}}", "message_other": "Witaj {{name}}"]
		localized[key] = "Witaj {{renamed}}"
		#expect(
			issues(english: english, localized: localized, tag: "pl") == [
				"pl has different placeholders for \(key)"
			])
		localized[key] = "Witaj {{name}}"
		#expect(issues(english: english, localized: localized, tag: "pl").isEmpty)
	}

	@Test(arguments: LanguageTag.allCases)
	func wordingCanChangeWithoutChangingPlaceholders(_ tag: LanguageTag) {
		#expect(
			issues(
				english: ["message": "Hello {{first}} {{last}}"],
				localized: ["message": "{{ last }} et {{first}}, bonjour {{first}}!"],
				tag: tag.rawValue
			).isEmpty)
	}

	private func issues(
		english: [String: String], localized: [String: String], tag: String,
		exceptions: [String: String] = [:]
	) -> [String] {
		var result: [String] = []
		for key in english.keys.sorted() {
			let required =
				["ja", "ko", "zh-Hans", "zh-Hant"].contains(tag) && key.hasSuffix("_one")
				? String(key.dropLast(4)) + "_other" : key
			if localized[required] == nil {
				result.append("\(tag) is missing \(required)")
			}
		}
		for key in localized.keys.sorted() {
			let pluralVariant = tag == "pl" && (key.hasSuffix("_few") || key.hasSuffix("_many"))
			let englishKey =
				pluralVariant ? String(key.dropLast(key.hasSuffix("_few") ? 4 : 5)) + "_other" : key
			guard let source = english[englishKey] else {
				result.append("\(tag) has an unexpected key \(key)")
				continue
			}
			guard let value = localized[key],
				!value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
			else {
				result.append("\(tag) has an empty value for \(key)")
				continue
			}
			if tag != "en", value == source, exceptions[key] != value {
				result.append("\(tag) copies English for \(key)")
			}
			if placeholders(value) != placeholders(source) {
				result.append("\(tag) has different placeholders for \(key)")
			}
		}
		return result
	}

	private func placeholders(_ value: String) -> Set<String> {
		Set(
			value.matches(of: /\{\{\s*([^{}]+?)\s*\}\}/).map {
				String($0.1).trimmingCharacters(in: .whitespacesAndNewlines)
			})
	}

	private func sharedValues(for tag: String) throws -> [String: String] {
		let url = try #require(
			Bundle.module.url(
				forResource: "CatalogSharedValues", withExtension: "tsv", subdirectory: "Fixtures"))
		let rows = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
		var values: [String: String] = [:]
		for row in rows {
			let fields = row.split(separator: "\t", omittingEmptySubsequences: false).map(
				String.init)
			try #require(fields.count == 4)
			try #require(
				!fields[3].trimmingCharacters(in: .whitespaces).isEmpty,
				"Shared catalog value needs a reason")
			if fields[0].split(separator: ",").contains(Substring(tag)) {
				try #require(
					values.updateValue(fields[2], forKey: fields[1]) == nil,
					"Duplicate shared catalog value")
			}
		}
		return values
	}

	private var catalogs: URL {
		var root = URL(filePath: #filePath)
		for _ in 0..<7 {
			root.deleteLastPathComponent()
		}
		return root.appending(path: "packages/i18n/catalogs")
	}

	private func leaves(in url: URL) throws -> [String: String] {
		let value = try JSONValue.parse(String(contentsOf: url, encoding: .utf8))
		return leaves(value)
	}

	private func leaves(_ value: JSONValue, prefix: String = "") -> [String: String] {
		switch value {
		case .string(let text):
			return [prefix: text]
		case .object(let fields):
			return fields.reduce(into: [:]) { result, field in
				let key = prefix.isEmpty ? field.key : "\(prefix).\(field.key)"
				result.merge(leaves(field.value, prefix: key)) { first, _ in first }
			}
		default:
			return [:]
		}
	}
}
