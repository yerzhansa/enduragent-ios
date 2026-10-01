import Foundation
import Testing

@testable import EnduragentCoach

@Suite struct ReplySourceTests {
	@Test(arguments: [
		"[call](tel:+15550100)", "[app](custom://path)", "[relative](/calendar)",
		"[**call**](tel:1)", "[é 🚴 \\[shop\\]](tel:1)", "[label](custom://a(b)c)",
		"[one](tel:1)[two](tel:1)", "<tel:+15550100>",
		"[label](custom://a'b)", "[label](custom://a \"title (kept)\")",
	]) func unsafeLinksKeepTheirExactLiteralSource(source: String) {
		#expect(
			ReplyParser.foundation.document(source) == .blocks([.paragraph([.literal(source)])]))
		#expect(ReplyParser.foundation.document(source).accessibilityText == source)
	}

	@Test func safeLabelsKeepTheirStylesAndAutolinksKeepLiteralURLCharacters() {
		let parsed = ReplyParser.foundation.document("[plain **bold** *ital*](https://example.com)")
		guard case .blocks(let blocks) = parsed, case .paragraph(let runs) = blocks.first,
			case .link(let label, _) = runs.first
		else {
			Issue.record("Expected a formatted link")
			return
		}
		#expect(
			label == [
				StyledText(text: "plain ", styles: []), StyledText(text: "bold", styles: [.bold]),
				StyledText(text: " ", styles: []), StyledText(text: "ital", styles: [.italic]),
			])
		#expect(
			ReplyParser.foundation.document("<https://example.com/a*b*c>").accessibilityText
				== "https://example.com/a*b*c")
	}

	@Test func referenceLinkKeepsTokenAndSafeReferenceBecomesALink() throws {
		let source = "[call][phone] and [web][site]\n\n[phone]: tel:1\n[site]: https://example.com"
		guard case .blocks(let blocks) = ReplyParser.foundation.document(source),
			case .paragraph(let runs) = blocks.first
		else {
			Issue.record("Expected a paragraph")
			return
		}
		#expect(runs.first == .literal("[call][phone]"))
		guard case .link(let label, let target) = runs.last else {
			Issue.record("Expected a safe reference link")
			return
		}
		#expect(label.map(\.text).joined() == "web")
		#expect(target.url.absoluteString == "https://example.com")
	}

	@Test(arguments: ["HTTPS://example.com/path", "http://example.com", "https://example.com"])
	func safeLinksCarryValidatedURLs(target: String) throws {
		guard case .blocks(let blocks) = ReplyParser.foundation.document("[web](\(target))"),
			case .paragraph(let runs) = blocks.first,
			case .link(let label, let link) = runs.first
		else {
			Issue.record("Expected a safe link")
			return
		}
		#expect(label == [StyledText(text: "web", styles: [])])
		#expect(link.url.absoluteString == target)
		#expect(HTTPLink(validating: try #require(URL(string: "https:relative"))) == nil)
	}

	@Test func unsupportedBlocksAndHTMLStayLiteral() {
		let source = "> **quoted**\n> second\n\n* * *\n\n<div>\n**not bold**\n</div>"
		#expect(
			ReplyParser.foundation.document(source)
				== .blocks([
					.paragraph([.literal("> **quoted**\n> second")]),
					.paragraph([.literal("* * *")]),
					.paragraph([.literal("<div>\n**not bold**\n</div>\n")]),
				]))
		#expect(
			ReplyParser.foundation.document("before <b>not bold</b> after").accessibilityText
				== "before <b>not bold</b> after")
	}

	@Test func ruleRecoveryDoesNotReadMarkersInsideCodeOrReferenceDefinitions() {
		let source = "```\n---\n```\n\n[unused]: tel:1\n\n___\n\n---\n\nafter"
		#expect(
			ReplyParser.foundation.document(source)
				== .blocks([
					.codeBlock(text: "---\n", language: nil), .paragraph([.literal("___")]),
					.paragraph([.literal("---")]),
					.paragraph([.text(StyledText(text: "after", styles: []))]),
				]))
	}

	@Test func foundationTableIntentsIncludeColumnRowAndCellIdentities() throws {
		let parsed = try decode("| Day | Load |\n| :--- | ---: |\n| Tue | **48** |\n| Thu | 82 |")
		let runs = Array(parsed.runs)
		let first = try #require(runs.first?.presentationIntent?.components)
		#expect(
			first.map(\.kind) == [
				.tableCell(columnIndex: 0), .tableHeaderRow,
				.table(columns: [
					.init(alignment: .left), .init(alignment: .right),
				]),
			])
		let row = try #require(runs.dropFirst(2).first?.presentationIntent?.components)
		#expect(
			row.map(\.kind) == [.tableCell(columnIndex: 0), .tableRow(rowIndex: 1), first[2].kind])
		#expect(row[2].identity == first[2].identity)
		#expect(row[1].identity != first[1].identity)
	}

	@Test func foundationNestedListAncestorsAreInnermostFirst() throws {
		let parsed = try decode("3. outer\n   - inner\n     1. deep\n   - sibling\n4. last")
		let runs = Array(parsed.runs)
		let deep = try #require(runs.dropFirst(2).first?.presentationIntent?.components)
		#expect(
			deep.map(\.kind) == [
				.paragraph, .listItem(ordinal: 1), .orderedList,
				.listItem(ordinal: 1), .unorderedList, .listItem(ordinal: 3), .orderedList,
			])
		let outer = try #require(runs.first?.presentationIntent?.components)
		#expect(deep.last?.identity == outer.last?.identity)
		#expect(deep[5].identity == outer[1].identity)
	}

	@Test func foundationInlineIntentsBreaksAndHTMLArePinned() throws {
		let styles = try decode("**bold** *italic* ~~gone~~ `code`")
		#expect(
			styles.runs.compactMap(\.inlinePresentationIntent) == [
				.stronglyEmphasized, .emphasized, .strikethrough, .code,
			])
		let breaks = try decode("one\ntwo  \nthree")
		#expect(String(breaks.characters) == "one two\nthree")
		#expect(breaks.runs.compactMap(\.inlinePresentationIntent) == [.softBreak, .lineBreak])
		let html = try decode("<div>\n**not bold**\n</div>")
		#expect(String(html.characters) == "<div>\n**not bold**\n</div>\n")
		#expect(html.runs.first?.inlinePresentationIntent == .blockHTML)
		#expect(html.runs.first?.presentationIntent == nil)
	}

	@Test func foundationLinkPositionsCoverLabelsAndRulesHaveNoPosition() throws {
		let source = "[**call**](tel:1)\n\n---"
		let parsed = try decode(source)
		let first = try #require(parsed.runs.first)
		let range = try #require(
			first.markdownSourcePosition.flatMap { Range<String.Index>($0, in: source) })
		#expect(String(source[range]) == "**call**")
		#expect(first.link?.absoluteString == "tel:1")
		#expect(first.inlinePresentationIntent == nil)
		#expect(parsed.runs.last?.markdownSourcePosition == nil)
		#expect(parsed.runs.last?.presentationIntent?.components.first?.kind == .thematicBreak)
	}

	@Test func foundationKeepsLongCodeCompleteAndAcceptsIncompleteSyntax() throws {
		let code = String(repeating: "x", count: 5_000) + "\nlast code line\n"
		let parsed = try decode(
			"```swift\n" + code + "```\n\n[tail](https://example.com)\n\nLAST LINE")
		let runs = Array(parsed.runs)
		#expect(String(parsed[try #require(runs.first?.range)].characters) == code)
		#expect(
			runs.first?.presentationIntent?.components.first?.kind
				== .codeBlock(languageHint: "swift"))
		#expect(runs.filter { $0.link != nil }.count == 1)
		#expect(String(parsed.characters).hasSuffix("LAST LINE"))
		#expect(String(try decode("[bad](").characters) == "[bad](")
		do {
			_ = try AttributedString(markdown: Data([0xff, 0xfe]), options: options)
			Issue.record("Invalid UTF-8 must throw")
		} catch {
			let error = error as NSError
			#expect(error.domain == NSCocoaErrorDomain)
			#expect(error.code == 259)
		}
	}

	@Test func missingSourceMappingFallsBackToTheWholeReply() throws {
		let url = try #require(URL(string: "tel:1"))
		let parser = ReplyParser { _ in
			var parsed = AttributedString("call")
			parsed.link = url
			parsed.presentationIntent = PresentationIntent(.paragraph, identity: 1)
			return parsed
		}
		#expect(
			parser.document("[call](tel:1)")
				== .plainText(source: "[call](tel:1)", failure: .sourceMapping))
	}

	private var options: AttributedString.MarkdownParsingOptions {
		.init(
			interpretedSyntax: .full, failurePolicy: .throwError,
			appliesSourcePositionAttributes: true)
	}

	private func decode(_ source: String) throws -> AttributedString {
		try AttributedString(markdown: source, options: options)
	}
}
