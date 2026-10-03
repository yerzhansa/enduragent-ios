import Foundation

public typealias DisplayLocaleResolver = @Sendable (LanguagePreference) -> DisplayLocale

public struct DisplayLocale: Sendable, Equatable {
	public let language: LanguageTag
	public let regionalConventions: Locale

	public init(
		preference: LanguagePreference, preferredLanguages: [String], regionalConventions: Locale
	) {
		language = preference.appLanguage(
			device: Language.uiTag(systemLanguages: preferredLanguages))
		self.regionalConventions = regionalConventions
	}

	public var phrasebook: CatalogPhrasebook { language.phrasebook }

	public func date(_ day: CivilDate, style: DisplayDateStyle) -> String {
		let parts = day.rawValue.split(separator: "-").compactMap { Int($0) }
		var calendar = Calendar(identifier: .gregorian)
		calendar.timeZone = .gmt
		guard
			let instant = calendar.date(
				from: DateComponents(
					year: parts[0], month: parts[1], day: parts[2], hour: 12))
		else {
			preconditionFailure("A validated civil day must have a Gregorian instant")
		}
		return DisplayDateFormatter.make(
			language: language, region: regionalConventions, style: style
		)
		.string(from: instant)
	}

	public func integer(_ value: Int) -> String {
		formatted(NSNumber(value: value), precision: .whole)
	}

	public func number(_ value: Double?, precision: DisplayPrecision) -> String {
		guard let value else { return "—" }
		return formatted(NSNumber(value: value), precision: precision)
	}

	public func clock(_ instant: Date, in zone: TimeZone) -> String {
		let formatter = DisplayDateFormatter.clock(language: language, region: regionalConventions)
		formatter.timeZone = zone
		return formatter.string(from: instant)
	}

	public func say(
		_ key: CatalogKey, count: Int? = nil, _ arguments: [String: CatalogArgument] = [:]
	) -> String {
		phrasebook.say(
			key, count: count,
			arguments.mapValues { argument in
				switch argument {
				case .text(let text): text
				case .integer(let value): integer(value)
				case .decimal(let value, let precision): number(value, precision: precision)
				case .day(let day): date(day, style: .numeric)
				}
			})
	}

	public static func == (lhs: Self, rhs: Self) -> Bool {
		lhs.language == rhs.language && lhs.conventions == rhs.conventions
	}

	package var formattingInstruction: String {
		let region = regionalConventions.region?.identifier ?? regionalConventions.identifier
		let instant = Date(timeIntervalSince1970: 1_772_629_500)
		return
			"For prose, use iPhone region \(region) for date order, decimal separators and clock format; month and weekday words follow \(language.englishName); examples: \(date("2026-03-04", style: .numeric)), \(date("2026-03-04", style: .named)), \(number(1234.5, precision: .tenths)), \(clock(instant, in: .gmt)); leave serialized dates, numbers, units, tool arguments and identifiers unchanged."
	}

	private var conventions: [String] {
		let numeric = DisplayDateFormatter.make(
			language: language, region: regionalConventions, style: .numeric)
		let named = DisplayDateFormatter.make(
			language: language, region: regionalConventions, style: .named)
		let clock = DisplayDateFormatter.clock(language: language, region: regionalConventions)
		let numbers = numberFormatter(precision: .compact)
		return [
			numeric.dateFormat ?? "", named.dateFormat ?? "", clock.dateFormat ?? "",
			String(describing: regionalConventions.calendar.identifier),
			integer(1_234_567), number(-1234.567, precision: .tenths),
			numbers.decimalSeparator ?? "", numbers.groupingSeparator ?? "",
			String(numbers.groupingSize), String(numbers.secondaryGroupingSize),
		]
	}

	private func formatted(_ value: NSNumber, precision: DisplayPrecision) -> String {
		guard let result = numberFormatter(precision: precision).string(from: value) else {
			preconditionFailure("Display quantities must be finite numbers")
		}
		return result
	}

	private func numberFormatter(precision: DisplayPrecision) -> NumberFormatter {
		let formatter = NumberFormatter()
		formatter.locale = regionalConventions
		formatter.numberStyle = .decimal
		formatter.roundingMode = .halfUp
		switch precision {
		case .whole:
			formatter.minimumFractionDigits = 0
			formatter.maximumFractionDigits = 0
		case .tenths:
			formatter.minimumFractionDigits = 1
			formatter.maximumFractionDigits = 1
		case .compact:
			formatter.minimumFractionDigits = 0
			formatter.maximumFractionDigits = 15
			formatter.usesGroupingSeparator = false
		}
		return formatter
	}
}
