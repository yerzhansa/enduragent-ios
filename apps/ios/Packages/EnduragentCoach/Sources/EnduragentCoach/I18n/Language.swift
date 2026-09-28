import Foundation

public enum LanguageTag: String, Sendable, CaseIterable {
	case en
	case es
	case fr
	case it
	case de
	case nl
	case da
	case sv
	case nb
	case fi
	case ptPT = "pt-PT"
	case ptBR = "pt-BR"
	case pl
	case ko
	case ja
	case zhHans = "zh-Hans"
	case zhHant = "zh-Hant"

	public var endonym: String {
		switch self {
		case .en: "English"
		case .es: "Español"
		case .fr: "Français"
		case .it: "Italiano"
		case .de: "Deutsch"
		case .nl: "Nederlands"
		case .da: "Dansk"
		case .sv: "Svenska"
		case .nb: "Norsk bokmål"
		case .fi: "Suomi"
		case .ptPT: "Português (Portugal)"
		case .ptBR: "Português (Brasil)"
		case .pl: "Polski"
		case .ko: "한국어"
		case .ja: "日本語"
		case .zhHans: "简体中文"
		case .zhHant: "繁體中文"
		}
	}

	public var englishName: String {
		switch self {
		case .en: "English"
		case .es: "Spanish"
		case .fr: "French"
		case .it: "Italian"
		case .de: "German"
		case .nl: "Dutch"
		case .da: "Danish"
		case .sv: "Swedish"
		case .nb: "Norwegian Bokmål"
		case .fi: "Finnish"
		case .ptPT: "Portuguese (Portugal)"
		case .ptBR: "Portuguese (Brazil)"
		case .pl: "Polish"
		case .ko: "Korean"
		case .ja: "Japanese"
		case .zhHans: "Simplified Chinese"
		case .zhHant: "Traditional Chinese"
		}
	}

	public var defaultLocale: String {
		switch self {
		case .en: "en-GB"
		case .es: "es-ES"
		case .fr: "fr-FR"
		case .it: "it-IT"
		case .de: "de-DE"
		case .nl: "nl-NL"
		case .da: "da-DK"
		case .sv: "sv-SE"
		case .nb: "nb-NO"
		case .fi: "fi-FI"
		case .ptPT: "pt-PT"
		case .ptBR: "pt-BR"
		case .pl: "pl-PL"
		case .ko: "ko-KR"
		case .ja: "ja-JP"
		case .zhHans: "zh-Hans-CN"
		case .zhHant: "zh-Hant-TW"
		}
	}

	public static let contractOrder: [LanguageTag] = [
		.en, .es, .fr, .it, .de, .nl, .da, .sv, .nb, .fi, .ptPT, .ptBR, .pl, .ko, .ja, .zhHans,
		.zhHant,
	]
}

public enum LanguageSource: String, Sendable {
	case preference
	case message
	case surface
	case `default`
}

public struct LanguageResolution: Sendable, Equatable {
	public var language: LanguageTag
	public var source: LanguageSource
	public var locale: String

	public init(language: LanguageTag, source: LanguageSource, locale: String) {
		self.language = language
		self.source = source
		self.locale = locale
	}
}

public struct CatalogKey: Hashable, Sendable, RawRepresentable {
	public let rawValue: String

	public init(rawValue: String) {
		self.rawValue = rawValue
	}
}

public struct Language {
	public static func resolve(
		saved: LanguageTag?,
		messageHint: LanguageTag?,
		surface: LanguageTag?
	) -> LanguageResolution {
		if let saved {
			return LanguageResolution(
				language: saved, source: .preference, locale: saved.defaultLocale)
		}
		if let messageHint {
			return LanguageResolution(
				language: messageHint, source: .message, locale: messageHint.defaultLocale)
		}
		if let surface {
			return LanguageResolution(
				language: surface, source: .surface, locale: surface.defaultLocale)
		}
		return LanguageResolution(
			language: .en, source: .default, locale: LanguageTag.en.defaultLocale)
	}

	public static func detectMessageLanguage(_ text: String) -> LanguageTag? {
		MessageLanguage.detect(text)
	}

	public static func uiTag(systemLanguages: [String]) -> LanguageTag {
		normalizeLocaleHint(systemLanguages) ?? .en
	}

	public static func normalizeLocaleHint(_ hint: String) -> LanguageTag? {
		normalizeLocaleHint([hint])
	}

	public static func normalizeLocaleHint(_ hints: [String]) -> LanguageTag? {
		for entry in hints {
			for candidate in entry.split(separator: ":", omittingEmptySubsequences: false) {
				let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
				let head =
					trimmed.split(
						maxSplits: 1, omittingEmptySubsequences: false,
						whereSeparator: { $0 == "." || $0 == "@" }
					)
					.first.map(String.init) ?? ""
				let normalized = head.replacingOccurrences(of: "_", with: "-").lowercased()
				if normalized.isEmpty || normalized == "c" || normalized == "posix" { continue }
				let pieces = normalized.split(separator: "-", omittingEmptySubsequences: false).map(
					String.init)
				guard let base = pieces.first else { continue }
				let parts = Array(pieces.dropFirst())
				if base == "no" || base == "nn" { return .nb }
				if base == "pt" { return parts.contains("br") ? .ptBR : .ptPT }
				if base == "zh" {
					if parts.contains("hant") { return .zhHant }
					if parts.contains("hans") { return .zhHans }
					let traditionalRegion =
						parts.contains("tw") || parts.contains("hk") || parts.contains("mo")
					return traditionalRegion ? .zhHant : .zhHans
				}
				if let tag = LanguageTag(rawValue: base) { return tag }
			}
		}
		return nil
	}
}

public protocol Phrasebook: Sendable {
	func say(_ key: CatalogKey, _ vars: [String: String]) -> String
}

public struct CatalogPhrasebook: Phrasebook {
	public let tag: LanguageTag
	public let locale: String

	public init(tag: LanguageTag, locale: String) {
		self.tag = tag
		self.locale = locale
	}

	public func say(_ key: CatalogKey, _ vars: [String: String] = [:]) -> String {
		let resolved = render(key.rawValue, tag: tag, vars: vars)
		let fallback = render(key.rawValue, tag: .en, vars: vars)
		let text: String
		if resolved.isEmpty || resolved == key.rawValue {
			text = fallback == key.rawValue ? "" : fallback
		} else {
			text = resolved
		}
		return text
	}

	private func render(_ key: String, tag: LanguageTag, vars: [String: String]) -> String {
		guard
			let template = CatalogStore.template(
				key: key, tag: tag, count: parsedCount(vars["count"]))
		else {
			return ""
		}
		return interpolate(template, vars: vars)
	}
}

private enum CatalogStore {
	static let file: XCStringsFile = load()

	static func template(key: String, tag: LanguageTag, count: Int?) -> String? {
		let (lookupKey, forcedForm) = splitPluralKey(key)
		guard let entry = file.strings[lookupKey] else { return nil }
		let localization =
			entry.localizations[tag.rawValue] ?? entry.localizations[LanguageTag.en.rawValue]
		guard let localization else { return nil }
		if let unit = localization.stringUnit?.value {
			return unit
		}
		guard let forms = localization.variations?.plural else { return nil }
		if let forcedForm, let value = forms[forcedForm]?.stringUnit?.value {
			return value
		}
		if let count {
			let category = pluralCategory(tag: tag, count: count)
			return forms[category]?.stringUnit?.value ?? forms["other"]?.stringUnit?.value
		}
		return forms["other"]?.stringUnit?.value
			?? forms.lazy.compactMap(\.value.stringUnit?.value).first
	}

	private static func load() -> XCStringsFile {
		let urls = [
			Bundle.module.url(forResource: "Phrasebook", withExtension: "json"),
			Bundle.module.url(
				forResource: "Phrasebook", withExtension: "json", subdirectory: "Resources"),
		]
		guard let url = urls.compactMap({ $0 }).first else {
			fatalError("Phrasebook.json is missing from the coach bundle")
		}
		do {
			let data = try Data(contentsOf: url)
			return try JSONDecoder().decode(XCStringsFile.self, from: data)
		} catch {
			fatalError("Phrasebook.json is unreadable: \(error)")
		}
	}
}

private struct XCStringsFile: Decodable, Sendable {
	var strings: [String: XCStringEntry]
}

private struct XCStringEntry: Decodable, Sendable {
	var localizations: [String: XCLocalization]
}

private struct XCLocalization: Decodable, Sendable {
	var stringUnit: XCStringUnit?
	var variations: XCVariations?
}

private struct XCVariations: Decodable, Sendable {
	var plural: [String: XCPluralForm]?
}

private struct XCPluralForm: Decodable, Sendable {
	var stringUnit: XCStringUnit?
}

private struct XCStringUnit: Decodable, Sendable {
	var value: String
}

private func splitPluralKey(_ key: String) -> (String, String?) {
	let suffix = /_(zero|one|two|few|many|other)$/
	guard let match = key.firstMatch(of: suffix) else { return (key, nil) }
	return (String(key[..<match.range.lowerBound]), String(match.1))
}

private func parsedCount(_ raw: String?) -> Int? {
	guard let raw else { return nil }
	if let value = Int(raw) { return value }
	guard let value = Double(raw) else { return nil }
	if value.rounded(.towardZero) == value { return Int(value) }
	return nil
}

private func pluralCategory(tag: LanguageTag, count: Int) -> String {
	let n = abs(count)
	switch tag {
	case .ja, .ko, .zhHans, .zhHant:
		return "other"
	case .pl:
		if n == 1 { return "one" }
		let mod10 = n % 10
		let mod100 = n % 100
		if (2...4).contains(mod10) && !(12...14).contains(mod100) { return "few" }
		return "many"
	case .fr, .ptBR:
		return n == 0 || n == 1 ? "one" : "other"
	case .en, .es, .it, .de, .nl, .da, .sv, .nb, .fi, .ptPT:
		return n == 1 ? "one" : "other"
	}
}

private func interpolate(_ template: String, vars: [String: String]) -> String {
	let named = template.replacing(/%#@([A-Za-z_][A-Za-z0-9_]*)@/) { match in
		vars[String(match.1)] ?? ""
	}
	return named.replacingOccurrences(of: "%%", with: "%")
}
