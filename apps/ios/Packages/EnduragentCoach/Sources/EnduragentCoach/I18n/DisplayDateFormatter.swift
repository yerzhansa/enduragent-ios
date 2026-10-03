import Foundation

package enum DisplayDateFormatter {
	package static func make(language: LanguageTag, region: Locale, style: DisplayDateStyle)
		-> DateFormatter
	{
		let formatter = DateFormatter()
		formatter.locale = formattingLocale(region)
		formatter.calendar = region.calendar
		formatter.timeZone = .gmt
		switch style {
		case .numeric: formatter.setLocalizedDateFormatFromTemplate("yMd")
		case .named: formatter.dateStyle = .full
		}
		return localize(formatter, language: language, style: style)
	}

	package static func clock(language: LanguageTag, region: Locale) -> DateFormatter {
		let formatter = DateFormatter()
		formatter.locale = formattingLocale(region)
		formatter.calendar = region.calendar
		formatter.timeZone = .gmt
		formatter.setLocalizedDateFormatFromTemplate("jmm")
		return localize(formatter, language: language, style: nil)
	}

	private static func formattingLocale(_ region: Locale) -> Locale {
		guard let territory = region.region?.identifier else { return region }
		var components = Locale.Components(locale: region)
		components.languageComponents = Locale.Language.Components(
			identifier: Locale.Language(identifier: "und-\(territory)").maximalIdentifier)
		components.hourCycle = region.hourCycle
		components.numberingSystem = region.numberingSystem
		return Locale(components: components)
	}

	private static func localize(
		_ formatter: DateFormatter, language: LanguageTag, style: DisplayDateStyle?
	) -> DateFormatter {
		let words = DateFormatter()
		words.locale = Locale(identifier: language.rawValue)
		words.calendar = formatter.calendar
		if let style {
			switch style {
			case .numeric: words.setLocalizedDateFormatFromTemplate("yMd")
			case .named: words.dateStyle = .full
			}
		} else {
			words.setLocalizedDateFormatFromTemplate("jmm")
		}
		formatter.dateFormat = DisplayDatePattern.localize(
			formatter.dateFormat ?? "", words: words.dateFormat ?? "")
		formatter.monthSymbols = words.monthSymbols
		formatter.shortMonthSymbols = words.shortMonthSymbols
		formatter.veryShortMonthSymbols = words.veryShortMonthSymbols
		formatter.standaloneMonthSymbols = words.standaloneMonthSymbols
		formatter.shortStandaloneMonthSymbols = words.shortStandaloneMonthSymbols
		formatter.veryShortStandaloneMonthSymbols = words.veryShortStandaloneMonthSymbols
		formatter.weekdaySymbols = words.weekdaySymbols
		formatter.shortWeekdaySymbols = words.shortWeekdaySymbols
		formatter.veryShortWeekdaySymbols = words.veryShortWeekdaySymbols
		formatter.standaloneWeekdaySymbols = words.standaloneWeekdaySymbols
		formatter.shortStandaloneWeekdaySymbols = words.shortStandaloneWeekdaySymbols
		formatter.veryShortStandaloneWeekdaySymbols = words.veryShortStandaloneWeekdaySymbols
		formatter.eraSymbols = words.eraSymbols
		formatter.longEraSymbols = words.longEraSymbols
		formatter.amSymbol = words.amSymbol
		formatter.pmSymbol = words.pmSymbol
		return formatter
	}
}

private enum DisplayDatePattern {
	private enum Token {
		case field(String)
		case literal(String)

		var field: Character? {
			guard case .field(let value) = self else { return nil }
			return value.first
		}
	}

	static func localize(_ pattern: String, words: String) -> String {
		let regional = tokens(pattern)
		let language = tokens(words)
		return regional.enumerated().map { index, token in
			switch token {
			case .field(let field): return field
			case .literal(let text):
				guard text.contains(where: \.isLetter) else { return quoted(text) }
				let previous = regional.prefix(index).compactMap(\.field).last
				let next = regional.dropFirst(index + 1).compactMap(\.field).first
				let translated =
					language.enumerated().compactMap { offset, candidate -> String? in
						guard case .literal(let literal) = candidate,
							language.prefix(offset).compactMap(\.field).last == previous,
							language.dropFirst(offset + 1).compactMap(\.field).first == next
						else { return nil }
						return literal.filter(\.isLetter)
					}.first ?? ""
				let punctuation = text.filter { !$0.isLetter }
				return quoted(
					punctuation.trimmingCharacters(in: .whitespaces) + " " + translated + " ")
			}
		}.joined()
	}

	private static func quoted(_ text: String) -> String {
		guard !text.isEmpty else { return "" }
		return "'" + text.replacingOccurrences(of: "'", with: "''") + "'"
	}

	private static func tokens(_ pattern: String) -> [Token] {
		var result: [Token] = []
		var literal = ""
		var field = ""
		var quoted = false
		let characters = Array(pattern)
		var index = 0
		while index < characters.count {
			let character = characters[index]
			if character == "'" {
				if index + 1 < characters.count, characters[index + 1] == "'" {
					literal.append("'")
					index += 2
					continue
				}
				quoted.toggle()
			} else if !quoted && character.isASCII && character.isLetter {
				if !literal.isEmpty {
					result.append(.literal(literal))
					literal = ""
				}
				if field.first != character && !field.isEmpty {
					result.append(.field(field))
					field = ""
				}
				field.append(character)
			} else {
				if !field.isEmpty {
					result.append(.field(field))
					field = ""
				}
				literal.append(character)
			}
			index += 1
		}
		if !field.isEmpty { result.append(.field(field)) }
		if !literal.isEmpty { result.append(.literal(literal)) }
		return result
	}
}
