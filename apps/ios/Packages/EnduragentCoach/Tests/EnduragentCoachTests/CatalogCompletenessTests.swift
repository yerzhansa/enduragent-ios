import Foundation
import Testing

@testable import EnduragentCoach

@Suite struct CatalogCompletenessTests {
	@Test(arguments: LanguageTag.allCases)
	func everyEnglishKeyHasAValueInEveryLocale(_ tag: LanguageTag) throws {
		let english = try leaves(in: catalogs.appending(path: "en.json"))
		let localized = try leaves(in: catalogs.appending(path: "\(tag.rawValue).json"))
		#expect(LanguageTag.allCases.count == 17)
		for key in english.keys.sorted() {
			#expect(localized[key] != nil, "\(tag.rawValue) is missing \(key)")
		}
	}

	@Test(arguments: LanguageTag.allCases)
	func retiredChromeKeysStayAbsent(_ tag: LanguageTag) throws {
		let localized = try leaves(in: catalogs.appending(path: "\(tag.rawValue).json"))
		for key in [
			"sidebar.menu", "chat.title", "chat.addToCalendar",
			"chat.composer.messageField", "chat.composer.sendButton",
		] {
			#expect(localized[key] == nil, "\(tag.rawValue) retains \(key)")
		}
		#expect(localized["chat.menu"] != nil)
		#expect(localized["language.continue"] != nil)
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
