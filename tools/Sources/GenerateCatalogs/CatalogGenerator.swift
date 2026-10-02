import Foundation

struct CatalogFailure: Error, CustomStringConvertible {
	let description: String
}

struct CatalogGenerator {
	static let tags = [
		"en", "es", "fr", "it", "de", "nl", "da", "sv", "nb", "fi", "pt-PT", "pt-BR", "pl", "ko",
		"ja", "zh-Hans", "zh-Hant",
	]
	static let pluralForms = ["zero", "one", "two", "few", "many", "other"]
	static let englishFormOrder = ["one", "other", "zero", "two", "few", "many"]
	static let catalogDirectory = "packages/i18n/catalogs"
	static let swiftOutput =
		"apps/ios/Packages/EnduragentCoach/Sources/EnduragentCoach/I18n/CatalogKey.generated.swift"
	static let phrasebookOutput =
		"apps/ios/Packages/EnduragentCoach/Sources/EnduragentCoach/Resources/Phrasebook.json"

	let root: URL
	private let token = /\{\{\s*([^{}]+?)\s*\}\}/
	private let substitutionName = /[A-Za-z_][A-Za-z0-9_]*/
	private let swiftIdentifier = /[A-Za-z_][A-Za-z0-9]*/

	init(root: URL) {
		self.root = root
	}

	func generate() throws -> String {
		let englishNode = try load("en")
		let englishLeaves = try leafKeys(englishNode, prefix: "")
		let pluralBases = Set(
			englishLeaves.compactMap { strippingSuffix(of: $0, forms: ["one", "other"]) }
		).sorted()
		let catalogKeys = Set(englishLeaves + pluralBases).sorted()
		guard !catalogKeys.isEmpty else {
			throw CatalogFailure(description: "English catalog has no keys")
		}
		try validateSwiftNames(catalogKeys)

		var catalogs: [String: [String: String]] = [:]
		for tag in Self.tags {
			catalogs[tag] = tag == "en" ? flatten(englishNode) : flatten(try load(tag))
		}
		let english = catalogs["en", default: [:]]
		let pluralBaseSet = Set(pluralBases)
		let plainLeaves = englishLeaves.filter {
			strippingSuffix(of: $0, forms: Self.pluralForms) == nil
		}
		let phrasebookKeys = Set(plainLeaves + pluralBases).sorted()

		var strings: [Member] = []
		for key in phrasebookKeys {
			let localizations =
				pluralBaseSet.contains(key)
				? try pluralLocalizations(key, english: english, catalogs: catalogs)
				: try plainLocalizations(key, english: english, catalogs: catalogs)
			strings.append(Member(key, .object([Member("localizations", .object(localizations))])))
		}

		let swift =
			([
				"public enum Catalog {",
				"\tpublic static let englishLeafCount = \(englishLeaves.count)",
				"\tpublic static let keyCount = \(catalogKeys.count)",
			]
			+ catalogKeys.map {
				"\tpublic static let \(swiftName($0)) = CatalogKey(rawValue: \(OrderedJSON.quoted($0)))"
			} + ["}", ""]).joined(separator: "\n")
		let phrasebook = OrderedJSON.object([
			Member("sourceLanguage", .string("en")),
			Member("strings", .object(strings)),
			Member("version", .string("1.0")),
		])

		try writeIfChanged(Self.swiftOutput, swift)
		try writeIfChanged(Self.phrasebookOutput, "\(phrasebook.rendered())\n")
		return
			"\(englishLeaves.count) leaves, \(catalogKeys.count) keys, \(Self.tags.count) locales"
	}

	private func pluralLocalizations(
		_ key: String, english: [String: String], catalogs: [String: [String: String]]
	) throws -> [Member] {
		var englishNames: [String] = []
		for form in Self.englishFormOrder {
			guard let value = english["\(key)_\(form)"] else { continue }
			for name in try appleFormat(value).names where !englishNames.contains(name) {
				englishNames.append(name)
			}
		}
		let substitutions = substitutions(englishNames)
		var localizations: [Member] = []
		for tag in Self.tags {
			let catalog = catalogs[tag, default: [:]]
			var forms: [Member] = []
			for form in Self.pluralForms {
				guard let raw = catalog["\(key)_\(form)"] else { continue }
				forms.append(Member(form, .object([stringUnit(try appleFormat(raw).value)])))
			}
			guard !forms.isEmpty else { continue }
			let variations = Member("variations", .object([Member("plural", .object(forms))]))
			localizations.append(Member(tag, .object([variations] + substitutions)))
		}
		return localizations
	}

	private func plainLocalizations(
		_ key: String, english: [String: String], catalogs: [String: [String: String]]
	) throws -> [Member] {
		let substitutions = substitutions(try appleFormat(english[key] ?? "").names)
		var localizations: [Member] = []
		for tag in Self.tags {
			guard let raw = catalogs[tag, default: [:]][key] else { continue }
			let unit = stringUnit(try appleFormat(raw).value)
			localizations.append(Member(tag, .object([unit] + substitutions)))
		}
		return localizations
	}

	private func substitutions(_ names: [String]) -> [Member] {
		guard !names.isEmpty else { return [] }
		let entries = names.enumerated().map { index, name in
			Member(
				name,
				.object([
					Member("argNum", .integer(index + 1)),
					Member("formatSpecifier", .string("@")),
				]))
		}
		return [Member("substitutions", .object(entries))]
	}

	private func stringUnit(_ value: String) -> Member {
		Member(
			"stringUnit",
			.object([Member("state", .string("translated")), Member("value", .string(value))]))
	}

	private func appleFormat(_ value: String) throws -> (value: String, names: [String]) {
		var names: [String] = []
		var converted = ""
		var last = value.startIndex
		for match in value.matches(of: token) {
			let name = String(match.output.1).trimmingCharacters(in: .whitespacesAndNewlines)
			guard name.wholeMatch(of: substitutionName) != nil else {
				throw CatalogFailure(description: "Invalid substitution name \(name)")
			}
			converted += value[last..<match.range.lowerBound].replacingOccurrences(
				of: "%", with: "%%")
			converted += "%#@\(name)@"
			if !names.contains(name) {
				names.append(name)
			}
			last = match.range.upperBound
		}
		converted += value[last...].replacingOccurrences(of: "%", with: "%%")
		return (converted, names)
	}

	private func leafKeys(_ node: CatalogNode, prefix: String) throws -> [String] {
		switch node {
		case .text:
			return [prefix]
		case .group(let children):
			var keys: [String] = []
			for (key, child) in children {
				guard !key.isEmpty, !key.contains(".") else {
					throw CatalogFailure(description: "Invalid catalog property \(key)")
				}
				keys += try leafKeys(child, prefix: prefix.isEmpty ? key : "\(prefix).\(key)")
			}
			return keys
		}
	}

	private func flatten(_ node: CatalogNode, prefix: String = "") -> [String: String] {
		switch node {
		case .text(let value):
			return [prefix: value]
		case .group(let children):
			var flat: [String: String] = [:]
			for (key, child) in children {
				flat.merge(flatten(child, prefix: prefix.isEmpty ? key : "\(prefix).\(key)")) { $1 }
			}
			return flat
		}
	}

	private func strippingSuffix(of key: String, forms: [String]) -> String? {
		for form in forms where key.hasSuffix("_\(form)") {
			return String(key.dropLast(form.count + 1))
		}
		return nil
	}

	private func validateSwiftNames(_ keys: [String]) throws {
		var names: [String: String] = [:]
		for key in keys {
			let name = swiftName(key)
			guard name.wholeMatch(of: swiftIdentifier) != nil else {
				throw CatalogFailure(description: "Invalid Swift identifier \(name) for \(key)")
			}
			if let existing = names[name] {
				throw CatalogFailure(
					description: "Duplicate Swift identifier \(name) for \(existing) and \(key)")
			}
			names[name] = key
		}
	}

	private func swiftName(_ key: String) -> String {
		key.split(separator: ".", omittingEmptySubsequences: false).enumerated()
			.map { partIndex, part in
				part.split(separator: "_", omittingEmptySubsequences: false).enumerated()
					.map { segmentIndex, segment in
						partIndex == 0 && segmentIndex == 0
							? String(segment) : segment.prefix(1).uppercased() + segment.dropFirst()
					}
					.joined()
			}
			.joined()
	}

	private func load(_ tag: String) throws -> CatalogNode {
		let url = root.appendingPathComponent("\(Self.catalogDirectory)/\(tag).json")
		return try JSONDecoder().decode(CatalogNode.self, from: Data(contentsOf: url))
	}

	private func writeIfChanged(_ path: String, _ contents: String) throws {
		let url = root.appendingPathComponent(path)
		let data = Data(contents.utf8)
		guard FileManager.default.contents(atPath: url.path) != data else { return }
		try FileManager.default.createDirectory(
			at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
		try data.write(to: url)
	}
}
