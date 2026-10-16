import Foundation

public struct PatternMatch {
	public let index: Int
	public let end: Int
	public let groups: [String]

	public var text: String { groups[0] }
}

public final class JavaScriptPatterns {
	private var compiled: [String: NSRegularExpression] = [:]

	public init() {}

	public func matchAll(_ source: String, _ text: String) throws -> [PatternMatch] {
		try scan(source, text, ignoringCase: false, onlyFirst: false)
	}

	public func exec(_ source: String, _ text: String) throws -> PatternMatch? {
		try scan(source, text, ignoringCase: false, onlyFirst: true).first
	}

	public func test(_ source: String, _ text: String, ignoringCase: Bool = false) throws -> Bool {
		try !scan(source, text, ignoringCase: ignoringCase, onlyFirst: true).isEmpty
	}

	public func replaceAll(_ source: String, _ text: String, with replacement: String) throws
		-> String
	{
		var result = ""
		var position = 0
		for match in try matchAll(source, text) {
			result += text.slice(position, match.index) + replacement
			position = match.end
		}
		return result + text.slice(position, text.utf16.count)
	}

	public func split(_ source: String, _ text: String) throws -> [String] {
		var parts: [String] = []
		var position = 0
		for match in try matchAll(source, text) where match.end > match.index {
			parts.append(text.slice(position, match.index))
			position = match.end
		}
		return parts + [text.slice(position, text.utf16.count)]
	}

	private func expression(_ source: String, ignoringCase: Bool) throws -> NSRegularExpression {
		let key = "\(ignoringCase ? "i" : "-")\(source)"
		if let known = compiled[key] { return known }
		let expression = try NSRegularExpression(
			pattern: JavaScriptPatternTranslator.translate(source, ignoringCase: ignoringCase))
		compiled[key] = expression
		return expression
	}

	private func scan(
		_ source: String, _ text: String, ignoringCase: Bool, onlyFirst: Bool
	) throws -> [PatternMatch] {
		let expression = try expression(source, ignoringCase: ignoringCase)
		let units = text as NSString
		var matches: [PatternMatch] = []
		var gaveUp = false
		expression.enumerateMatches(
			in: text, options: [.reportCompletion],
			range: NSRange(location: 0, length: units.length)
		) { result, flags, stop in
			if flags.contains(.internalError) { gaveUp = true }
			guard let result else { return }
			let groups = (0..<result.numberOfRanges).map { group in
				let range = result.range(at: group)
				return range.location == NSNotFound ? "" : units.substring(with: range)
			}
			matches.append(
				PatternMatch(
					index: result.range.location, end: result.range.location + result.range.length,
					groups: groups))
			if onlyFirst { stop.pointee = true }
		}
		guard !gaveUp else {
			throw PatternFailure(description: "The pattern engine gave up on \(source)")
		}
		return matches
	}
}

extension String {
	public func slice(_ start: Int, _ end: Int) -> String {
		(self as NSString).substring(with: NSRange(location: start, length: end - start))
	}

	public func hasUnitPrefix(_ prefix: String) -> Bool {
		utf8.starts(with: prefix.utf8)
	}

	public func hasUnitSuffix(_ suffix: String) -> Bool {
		utf8.reversed().starts(with: suffix.utf8.reversed())
	}

	public func hasSameUnits(as other: String) -> Bool {
		utf8.elementsEqual(other.utf8)
	}
}
