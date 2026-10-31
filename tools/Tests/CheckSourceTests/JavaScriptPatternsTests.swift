import Testing

@testable import ToolSupport

struct JavaScriptPatternsTests {
	@Test(arguments: [
		PatternProbe(#"\bIF\b"#, in: "éIF 體IF資 xIF IF_ IF", finds: ["1:IF", "5:IF", "17:IF"]),
		PatternProbe(#"\w+"#, in: "aé٣_9 ſ\u{212A}", finds: ["0:a", "3:_9"]),
		PatternProbe(#"\d+"#, in: "12٣4", finds: ["0:12", "3:4"]),
		PatternProbe(
			#"a\sb"#, in: "a\u{0B}b a\u{FEFF}b a\u{85}b a\u{A0}b a\u{2028}b",
			finds: ["0:a\u{0B}b", "4:a\u{FEFF}b", "12:a\u{A0}b", "16:a\u{2028}b"]),
		PatternProbe(
			#"a.b"#, in: "a\u{85}b a\u{0C}b a\nb a\rb a\u{2028}b",
			finds: ["0:a\u{85}b", "4:a\u{0C}b"]),
		PatternProbe(#"x$"#, in: "x\nx", finds: ["2:x"]),
		PatternProbe(#"^x"#, in: "x\nx", finds: ["0:x"]),
		PatternProbe(
			#"(#+)?"a"\1"#, in: ##""a" #"a"# ##"a"#"##,
			finds: [#"0:"a""#, ##"4:#"a"#"##, ##"11:#"a"#"##]),
		PatternProbe(
			#"([^{};\n]*)([{};\n]|$)"#, in: "a{b;\n}c",
			finds: ["0:a{", "2:b;", "4:\n", "5:}", "6:c", "7:"]),
		PatternProbe(#"[\s\S]*?`"#, in: "a\n`b`", finds: ["0:a\n`", "3:b`"]),
		PatternProbe(#"[\w.]+"#, in: "a.b-c.d", finds: ["0:a.b", "4:c.d"]),
		PatternProbe(#"a{2,3}?b"#, in: "aaab aab ab", finds: ["0:aaab", "5:aab"]),
		PatternProbe(#"(a|b)+?c"#, in: "abc bc", finds: ["0:abc", "4:bc"]),
	])
	func findsWhatTheJavaScriptPatternFinds(_ probe: PatternProbe) throws {
		let found = try JavaScriptPatterns().matchAll(probe.source, probe.text).map {
			"\($0.index):\($0.text)"
		}

		#expect(found == probe.finds)
	}

	@Test(arguments: [
		LetterCaseProbe(#"k\.p8$"#, in: "K.P8", matches: true),
		LetterCaseProbe(#"[^/]+\.(?:p12|ipa)$"#, in: "x/Y.IPA", matches: true),
		LetterCaseProbe(#"k"#, in: "\u{212A}", matches: false),
		LetterCaseProbe(#"s"#, in: "ſ", matches: false),
	])
	func ignoresLetterCaseAsJavaScriptDoes(_ probe: LetterCaseProbe) throws {
		let matches = try JavaScriptPatterns().test(probe.source, probe.text, ignoringCase: true)

		#expect(matches == probe.matches)
	}

	@Test(arguments: [
		#"(?<=a)b"#, #"(?<name>a)"#, #"\p{L}"#, #"\u0041"#, #"\x41"#, #"a\B"#, #"(a)\1"#, "[]",
		"(a",
		"a)", "é",
		"(?:(a)|b)+", "((a)|b)*", "(?:(a))?", "((a)b)?", "(?:(a)){2}", "(?=(a))+",
		"a++", "a?+a", "(a)?*", "a**", "a{2}+", "a+??", "a{2}{3}",
	])
	func refusesAPatternItCannotTranslateExactly(_ source: String) {
		#expect(throws: PatternFailure.self) {
			try JavaScriptPatternTranslator.translate(source, ignoringCase: false)
		}
	}
}

struct PatternProbe: Sendable, CustomTestStringConvertible {
	let source: String
	let text: String
	let finds: [String]

	init(_ source: String, in text: String, finds: [String]) {
		self.source = source
		self.text = text
		self.finds = finds
	}

	var testDescription: String { "\(source) in \(text.quotedAsJSON)" }
}

struct LetterCaseProbe: Sendable, CustomTestStringConvertible {
	let source: String
	let text: String
	let matches: Bool

	init(_ source: String, in text: String, matches: Bool) {
		self.source = source
		self.text = text
		self.matches = matches
	}

	var testDescription: String { "\(source) in \(text.quotedAsJSON)" }
}
