import Foundation
import Testing

@testable import EnduragentCoach

@Suite struct ReplyLiteralTests {
	@Test(arguments: [
		("[call](tel:+15550100)", "[call](tel:+15550100)"),
		("[app](custom://path)", "[app](custom://path)"),
		("[relative](/calendar)", "[relative](/calendar)"),
		("[**call**](tel:1)", "[call](tel:1)"),
		("[é 🚴 \\[shop\\]](tel:1)", "[é 🚴 [shop]](tel:1)"),
		("[label](custom://a(b)c)", "[label](custom://a(b)c)"),
		("[one](tel:1)[two](tel:1)", "[onetwo](tel:1)"),
		("<tel:+15550100>", "[tel:+15550100](tel:+15550100)"),
		("[label](custom://a'b)", "[label](custom://a'b)"),
		("[label](custom://a \"title (kept)\")", "[label](custom://a)"),
		("[call][phone]\n\n[phone]: tel:1", "[call](tel:1)"),
	]) func unsafeLinksAreRebuiltFromParsedLabelsAndAddresses(source: String, literal: String) {
		let document = ReplyParser.foundation.document(source)
		#expect(document == .blocks([.paragraph([.literal(literal)])]))
		#expect(document.accessibilityText == literal)
	}

	@Test(arguments: [0, 5_000]) func angleDelimitedUnsafeLinksUseTheCompleteParsedAddress(
		prefixLength: Int
	) {
		let prefix = String(repeating: "x", count: prefixLength)
		let runs: [ReplyRun] =
			(prefix.isEmpty ? [] : [text(prefix)])
			+ [.literal("[app](custom://a)b)")]
		let document = ReplyParser.foundation.document(prefix + "[app](<custom://a)b>)")
		#expect(document == .blocks([.paragraph(runs)]))
		#expect(document.accessibilityText == prefix + "[app](custom://a)b)")
	}

	@Test(arguments: ["> text\n>\n> ---", "> text\n>\n> ---\n\nafter"])
	func quoteEndingWithARuleRebuildsEveryParsedChild(source: String) {
		let quote = ReplyBlock.paragraph([.literal("> text\n\n> ---")])
		let blocks: [ReplyBlock] =
			source.hasSuffix("after")
			? [quote, .paragraph([text("after")])] : [quote]
		#expect(ReplyParser.foundation.document(source) == .blocks(blocks))
	}

	@Test(arguments: [
		("before [](tel:1) after", "before  after"),
		("[](tel:1) after", " after"), ("before [](tel:1)", "before "),
		("before [](tel:1)\nafter", "before \nafter"),
		("before\n[](tel:1) after", "before\n after"),
		("**before [](tel:1) after**", "before  after"),
		("before [][phone] after\n\n[phone]: tel:1", "before  after"),
	]) func emptyUnsafeLinkLabelsShowNothingAndKeepSurroundingText(
		source: String, expected: String
	) {
		let document = ReplyParser.foundation.document(source)
		guard case .blocks(let blocks) = document else {
			Issue.record("Expected formatted surrounding text")
			return
		}
		#expect(document.accessibilityText == expected)
		#expect(blocks.count == 1)
	}

	@Test func emptyUnsafeLinkAloneAndInATableDoesNotRequireSourceRecovery() throws {
		#expect(ReplyParser.foundation.document("[](tel:1)") == .blocks([]))
		let document = ReplyParser.foundation.document(
			"| a | b |\n|---|---|\n| [](tel:1) | second |")
		guard case .blocks(let blocks) = document, case .table(let table) = blocks.first else {
			Issue.record("Expected a formatted table")
			return
		}
		#expect(table.rows == [[[], [text("second")]]])
		#expect(document.accessibilityText == "a\tb\n\tsecond")
	}

	@Test(arguments: [0, 5_000]) func crlfParagraphsKeepFormattingAndSafeLinks(prefixLength: Int)
		throws
	{
		let prefix = String(repeating: "x", count: prefixLength)
		let source = prefix + "**before**\r\n[web](https://example.com)"
		let url = try #require(URL(string: "https://example.com"))
		let target = try #require(HTTPLink(validating: url))
		let runs =
			(prefix.isEmpty ? [] : [text(prefix)]) + [
				text("before", [.bold]), text("\n"),
				.link(label: [StyledText(text: "web", styles: [])], target: target),
			]
		let document = ReplyParser.foundation.document(source)
		#expect(document == .blocks([.paragraph(runs)]))
		#expect(document.accessibilityText == prefix + "before\nweb")
	}

	@Test(arguments: [
		"3. outer\n   - inner\n4. [web](https://example.com)",
		"| a | b |\n|:---|---:|\n| **first** | [web](https://example.com) |",
		"```swift\nfirst\nlast\n```\n\n[web](https://example.com)",
	]) func crlfListsTablesAndCodeMatchParsedLFBlocks(source: String) {
		let expected = ReplyParser.foundation.document(source)
		let document = ReplyParser.foundation.document(
			source.replacingOccurrences(of: "\n", with: "\r\n"))
		guard case .blocks = expected, case .blocks = document else {
			Issue.record("Expected formatted blocks for both newline forms")
			return
		}
		#expect(document == expected)
		#expect(document.accessibilityText.contains("web"))
	}

	@Test(arguments: ["HTTPS://example.com/path", "http://example.com", "https://example.com"])
	func safeLinksCarryValidatedURLs(target: String) throws {
		guard case .blocks(let blocks) = ReplyParser.foundation.document("[web](\(target))"),
			case .paragraph(let runs) = blocks.first, case .link(let label, let link) = runs.first
		else {
			Issue.record("Expected a safe link")
			return
		}
		#expect(label == [StyledText(text: "web", styles: [])])
		#expect(link.url.absoluteString == target)
		#expect(HTTPLink(validating: try #require(URL(string: "https:relative"))) == nil)
	}

	@Test func supportedLinksUseParsedLabelsWithoutReparsingMarkdown() {
		#expect(
			ReplyParser.foundation.document("[plain **bold** *ital*](https://example.com)")
				.accessibilityText == "plain bold ital")
		#expect(
			ReplyParser.foundation.document("<https://example.com/a*b*c>").accessibilityText
				== "https://example.com/a*b*c")
	}

	@Test func unsupportedBlocksAndHTMLUseParsedText() {
		let source = "> **quoted**\n> second\n\n* * *\n\n<div>\n**not bold**\n</div>"
		#expect(
			ReplyParser.foundation.document(source)
				== .blocks([
					.paragraph([.literal("> quoted\n> second")]), .paragraph([.literal("---")]),
					.paragraph([.literal("<div>\n**not bold**\n</div>\n")]),
				]))
		#expect(
			ReplyParser.foundation.document("before <b>not bold</b> after").accessibilityText
				== "before <b>not bold</b> after")
		#expect(
			ReplyParser.foundation.document("> > inner\n>\n> outer").accessibilityText
				== "> > inner\n\n> outer")
	}

	@Test func ruleMarkersAreNormalizedWithoutChangingCodeText() {
		let source = "```\n---\n```\n\n[unused]: tel:1\n\n___\n\n---\n\nafter"
		#expect(
			ReplyParser.foundation.document(source)
				== .blocks([
					.codeBlock(text: "---\n", language: nil), .paragraph([.literal("---")]),
					.paragraph([.literal("---")]), .paragraph([text("after")]),
				]))
	}

	@Test func parsedRunsDoNotNeedSourcePositions() throws {
		let url = try #require(URL(string: "tel:1"))
		let parser = ReplyParser { _ in
			var parsed = AttributedString("call")
			parsed.link = url
			parsed.presentationIntent = PresentationIntent(.paragraph, identity: 1)
			return parsed
		}
		#expect(
			parser.document("different source")
				== .blocks([.paragraph([.literal("[call](tel:1)")])]))
	}

	private func text(_ value: String, _ styles: Set<InlineStyle> = []) -> ReplyRun {
		.text(StyledText(text: value, styles: styles))
	}
}
