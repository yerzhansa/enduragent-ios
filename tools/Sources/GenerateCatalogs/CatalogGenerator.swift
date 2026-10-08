import Foundation

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

	func generate() throws -> String {
		let englishNode = try load("en")
		let englishLeaves = try leafKeys(englishNode, prefix: "")
		let pluralBases = sorted(
			Set(englishLeaves.compactMap { strippingSuffix(of: $0, forms: ["one", "other"]) }))
		let catalogKeys = sorted(Set(englishLeaves + pluralBases))
		guard !catalogKeys.isEmpty else {
			throw CatalogFailure(description: "English catalog has no keys")
		}
		try validateSwiftNames(catalogKeys)

		var catalogs: [String: [String: String]] = [:]
		for tag in Self.tags {
			catalogs[tag] = try flatten(tag == "en" ? englishNode : try load(tag), tag: tag)
		}
		let english = catalogs["en", default: [:]]
		let pluralBaseSet = Set(pluralBases)
		let plainLeaves = englishLeaves.filter {
			strippingSuffix(of: $0, forms: Self.pluralForms) == nil
		}

		var strings: [Member] = []
		for key in sorted(Set(plainLeaves + pluralBases)) {
			let localizations =
				pluralBaseSet.contains(key)
				? try pluralLocalizations(key, english: english, catalogs: catalogs)
				: try plainLocalizations(key, english: english, catalogs: catalogs)
			strings.append(Member(key, .object([Member("localizations", .object(localizations))])))
		}

		let swift =
			(["public enum Catalog {"]
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
		let scalars = Array(value.unicodeScalars)
		var converted = String.UnicodeScalarView()
		var names: [String] = []
		var index = 0
		while index < scalars.count {
			if let token = token(in: scalars, at: index) {
				guard isName(token.name, underscoreAfterFirst: true) else {
					throw CatalogFailure(description: "Invalid substitution name \(token.name)")
				}
				converted.append(contentsOf: "%#@\(token.name)@".unicodeScalars)
				if !names.contains(token.name) {
					names.append(token.name)
				}
				index = token.end
			} else {
				if scalars[index] == "%" {
					converted.append("%")
				}
				converted.append(scalars[index])
				index += 1
			}
		}
		return (String(converted), names)
	}

	private func token(in scalars: [Unicode.Scalar], at start: Int) -> (name: String, end: Int)? {
		guard scalars[start...].starts(with: ["{", "{"]) else { return nil }
		let nameStart = start + 2
		let nameEnd = scalars[nameStart...].firstIndex { $0 == "{" || $0 == "}" } ?? scalars.count
		guard nameEnd > nameStart, scalars[nameEnd...].starts(with: ["}", "}"]) else { return nil }
		var name = scalars[nameStart..<nameEnd]
		while let first = name.first, Self.tokenPadding.contains(first) {
			name.removeFirst()
		}
		while let last = name.last, Self.tokenPadding.contains(last) {
			name.removeLast()
		}
		var text = String.UnicodeScalarView()
		text.append(contentsOf: name)
		return (String(text), nameEnd + 2)
	}

	private func leafKeys(_ node: CatalogNode, prefix: String) throws -> [String] {
		switch node {
		case .text:
			return [prefix]
		case .group(let members):
			var keys: [String] = []
			for member in members {
				guard !member.key.isEmpty, !member.key.unicodeScalars.contains(".") else {
					throw CatalogFailure(description: "Invalid catalog property \(member.key)")
				}
				keys += try leafKeys(
					member.value, prefix: prefix.isEmpty ? member.key : "\(prefix).\(member.key)")
			}
			return keys
		}
	}

	private func flatten(_ node: CatalogNode, tag: String) throws -> [String: String] {
		var flat: [String: String] = [:]
		try collect(node, prefix: "", tag: tag, into: &flat)
		return flat
	}

	private func collect(
		_ node: CatalogNode, prefix: String, tag: String, into flat: inout [String: String]
	) throws {
		switch node {
		case .text(let value):
			guard flat.updateValue(value, forKey: prefix) == nil else {
				throw CatalogFailure(description: "Two values for \(prefix) in catalog \(tag)")
			}
		case .group(let members):
			for member in members {
				try collect(
					member.value, prefix: prefix.isEmpty ? member.key : "\(prefix).\(member.key)",
					tag: tag, into: &flat)
			}
		}
	}

	private func strippingSuffix(of key: String, forms: [String]) -> String? {
		for form in forms where key.utf8.suffix(form.utf8.count + 1).elementsEqual("_\(form)".utf8)
		{
			return String(decoding: key.utf8.dropLast(form.utf8.count + 1), as: UTF8.self)
		}
		return nil
	}

	private func sorted(_ keys: Set<String>) -> [String] {
		keys.sorted { $0.utf16.lexicographicallyPrecedes($1.utf16) }
	}

	private func validateSwiftNames(_ keys: [String]) throws {
		var names: [String: String] = [:]
		for key in keys {
			let name = swiftName(key)
			guard isName(name, underscoreAfterFirst: false) else {
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
		var name = String.UnicodeScalarView()
		let parts = key.unicodeScalars.split(separator: ".", omittingEmptySubsequences: false)
		for (partIndex, part) in parts.enumerated() {
			let segments = part.split(separator: "_", omittingEmptySubsequences: false)
			for (segmentIndex, segment) in segments.enumerated() {
				guard let first = segment.first else { continue }
				if partIndex == 0 && segmentIndex == 0 {
					name.append(contentsOf: segment)
				} else {
					name.append(contentsOf: String(first).uppercased().unicodeScalars)
					name.append(contentsOf: segment.dropFirst())
				}
			}
		}
		return String(name)
	}

	private func load(_ tag: String) throws -> CatalogNode {
		let url = root.appendingPathComponent("\(Self.catalogDirectory)/\(tag).json")
		return try CatalogNode.read(String(decoding: Data(contentsOf: url), as: UTF8.self))
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

extension CatalogGenerator {
	fileprivate static let tokenPadding = Set(
		"\t\n\u{0B}\u{0C}\r \u{A0}\u{1680}\u{2028}\u{2029}\u{202F}\u{205F}\u{3000}\u{FEFF}"
			.unicodeScalars + (0x2000...0x200A).compactMap(Unicode.Scalar.init))

	fileprivate func isName(_ text: String, underscoreAfterFirst: Bool) -> Bool {
		let letter: (Unicode.Scalar) -> Bool = {
			("A"..."Z").contains($0) || ("a"..."z").contains($0)
		}
		guard let first = text.unicodeScalars.first, letter(first) || first == "_" else {
			return false
		}
		return text.unicodeScalars.dropFirst().allSatisfy {
			letter($0) || ("0"..."9").contains($0) || (underscoreAfterFirst && $0 == "_")
		}
	}
}
