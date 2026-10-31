import Foundation

package struct ScrubbedText: Sendable, Hashable, Codable {
	package let text: String

	package init(scrubbing raw: String) {
		text = Scrub.clean(raw)
	}

	package init(from decoder: any Decoder) throws {
		self.init(scrubbing: try decoder.singleValueContainer().decode(String.self))
	}

	package func encode(to encoder: any Encoder) throws {
		var container = encoder.singleValueContainer()
		try container.encode(text)
	}
}

package enum Scrub {
	package static let marker = "[redacted]"
	package static let limit = 2_000

	package static func clean(_ raw: String) -> String {
		var text = String(String.UnicodeScalarView(raw.unicodeScalars.filter { $0 != "\0" }))
		for pattern in patterns {
			text.replace(pattern, with: marker)
		}
		return cut(text)
	}

	private static var patterns: [Regex<Substring>] {
		[
			#/\b[a-z][a-z\d+.-]*:\/\/[^\s"'<>]+/#,
			#/\b(?:Bearer|Basic)\s+[^\s,;]+/#,
			#/\b(?:sk-|gh[pousr]_|github_pat_)[a-z\d_-]+/#,
		].map {
			$0.ignoresCase().wordBoundaryKind(.simple).asciiOnlyWordCharacters().asciiOnlyDigits()
				.matchingSemantics(.unicodeScalar)
		}
	}

	private static func cut(_ text: String) -> String {
		var units = 0
		var kept = String.UnicodeScalarView()
		for scalar in text.unicodeScalars {
			units += scalar.utf16.count
			guard units <= limit else { break }
			kept.append(scalar)
		}
		return String(kept)
	}
}
