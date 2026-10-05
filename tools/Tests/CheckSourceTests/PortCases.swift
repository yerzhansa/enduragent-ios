import Testing

@testable import CheckSource

extension SourceCases {
	static let failure = "check-source: inventory or file parsing failed; content omitted.\n"

	static let port: [SourceCase] = [
		.rejects(
			"rejects a training abbreviation between letters that are not ASCII",
			["packages/i18n/catalogs/zh-Hant.json": #"{"status":"正在取得體能CTL資料"}"#],
			finding: "public-language",
			findingLines: [#""packages/i18n/catalogs/zh-Hant.json" [public-language] "status""#]),
		.accepts(
			"accepts a catalog that starts with a byte order mark",
			["packages/i18n/catalogs/en.json": "\u{FEFF}{\"greeting\":\"Hello\"}"]),
		.accepts(
			"accepts a repeated catalog key whose last value is plain",
			["packages/i18n/catalogs/en.json": #"{"load":"Your CTL","load":"Your fitness"}"#]),
		.rejects(
			"rejects a forbidden path in another letter case", ["Docs/example.md": "text"],
			finding: #""Docs/example.md" [forbidden-path]"#),
		SourceCase(
			name: "stops without a verdict on a tracked file that is not UTF-8",
			runs: [
				Scratch(binaries: ["broken.txt": [0xFF, 0xFE, 0x41]], status: 2, output: failure)
			]),
	]
}

struct CheckSourceCommandTests {
	@Test
	func refusesArgumentsItDoesNotKnow() throws {
		var errors: [String] = []
		let status = try CheckSource.run(
			arguments: ["--repository", "."], directory: "/", output: { _ in },
			errors: { errors.append($0) })

		#expect(status == 2)
		#expect(errors == ["Usage: check-source [--root repository]"])
	}
}
