import EnduragentCoach
import XCTest

enum MatrixCatalogError: Error {
	case missingPhrasebook
}

struct MatrixCatalog {
	let tag: LanguageTag
	let keys: Set<String>
	private let ownSentences: Set<String>
	private let ownShapes: [NSRegularExpression]
	private let englishSentences: Set<String>
	private let englishShapes: [NSRegularExpression]

	@MainActor private static var loaded: [LanguageTag: MatrixCatalog] = [:]

	@MainActor
	static func load(_ tag: LanguageTag) throws -> MatrixCatalog {
		if let catalog = loaded[tag] { return catalog }
		let catalog = try MatrixCatalog(tag: tag, file: PhrasebookFile.read())
		loaded[tag] = catalog
		return catalog
	}

	private init(tag: LanguageTag, file: PhrasebookFile) throws {
		var ownSentences = Set<String>()
		var ownShapes: [NSRegularExpression] = []
		var englishSentences = Set<String>()
		var englishShapes: [NSRegularExpression] = []
		for entry in file.strings.values {
			let own = Set(entry.templates(for: tag))
			for template in own {
				if !template.contains(Self.placeholderMark) {
					ownSentences.insert(template)
				} else if Self.literalLetters(template, asciiOnly: false) >= 2 {
					ownShapes.append(try Self.shape(of: template))
				}
			}
			for template in entry.templates(for: .en) where !own.contains(template) {
				if !template.contains(Self.placeholderMark) {
					englishSentences.insert(template)
				} else if Self.literalLetters(template, asciiOnly: true) >= 4 {
					englishShapes.append(try Self.shape(of: template))
				}
			}
		}
		self.tag = tag
		self.keys = Set(file.strings.keys)
		self.ownSentences = ownSentences
		self.ownShapes = ownShapes
		self.englishSentences = englishSentences
		self.englishShapes = englishShapes
	}

	func isEnglishFallback(_ text: String) -> Bool {
		guard tag != .en, !ownSentences.contains(text) else { return false }
		guard englishSentences.contains(text) || Self.matches(text, anyOf: englishShapes) else {
			return false
		}
		return !Self.matches(text, anyOf: ownShapes)
	}

	func hasUnresolvedPlaceholder(_ text: String) -> Bool {
		text.contains(Self.placeholderMark) || text.contains("{{") || text.contains("}}")
	}

	private static let placeholderMark = "%#@"

	private static func literals(of template: String) -> [String] {
		var pieces: [String] = []
		var rest = Substring(template)
		while let start = rest.range(of: placeholderMark),
			let end = rest.range(of: "@", range: start.upperBound..<rest.endIndex)
		{
			pieces.append(String(rest[..<start.lowerBound]))
			rest = rest[end.upperBound...]
		}
		return pieces + [String(rest)]
	}

	private static func literalLetters(_ template: String, asciiOnly: Bool) -> Int {
		literals(of: template).joined().filter { $0.isLetter && (!asciiOnly || $0.isASCII) }.count
	}

	private static func shape(of template: String) throws -> NSRegularExpression {
		let pattern = literals(of: template).map(NSRegularExpression.escapedPattern(for:))
			.joined(separator: ".+?")
		return try NSRegularExpression(
			pattern: "^\(pattern)$", options: [.dotMatchesLineSeparators])
	}

	private static func matches(_ text: String, anyOf shapes: [NSRegularExpression]) -> Bool {
		let whole = NSRange(text.startIndex..., in: text)
		return shapes.contains { $0.firstMatch(in: text, range: whole) != nil }
	}
}

private struct PhrasebookFile: Decodable {
	var strings: [String: Entry]

	struct Entry: Decodable {
		var localizations: [String: Localization]

		func templates(for tag: LanguageTag) -> [String] {
			guard let localization = localizations[tag.rawValue] else { return [] }
			let values =
				localization.stringUnit.map { [$0.value] }
				?? (localization.variations?.plural ?? [:]).values.compactMap(\.stringUnit?.value)
			return values.map { $0.replacingOccurrences(of: "%%", with: "%") }
		}
	}

	struct Localization: Decodable {
		var stringUnit: Unit?
		var variations: Variations?
	}

	struct Variations: Decodable {
		var plural: [String: Form]?
	}

	struct Form: Decodable {
		var stringUnit: Unit?
	}

	struct Unit: Decodable {
		var value: String
	}

	static func read() throws -> PhrasebookFile {
		let tests = Bundle(for: LanguageMatrixEnSweep.self)
		guard
			let resources = tests.url(
				forResource: "EnduragentCoach_EnduragentCoach", withExtension: "bundle"),
			let phrasebook = Bundle(url: resources)?.url(
				forResource: "Phrasebook", withExtension: "json")
		else { throw MatrixCatalogError.missingPhrasebook }
		return try JSONDecoder().decode(PhrasebookFile.self, from: Data(contentsOf: phrasebook))
	}
}
