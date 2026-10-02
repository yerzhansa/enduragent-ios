import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

@Suite struct ReplyDocumentTests {
	@Test func headingsAndCombinedInlineStylesBecomeFormatting() throws {
		let source = "# Heading\n\n**bold** *italic* ~~gone~~ `238 W` ***both***"
		let blocks = try blocks(source)
		#expect(blocks.first == .heading(.one, [text("Heading")]))
		guard case .paragraph(let runs) = blocks.last else {
			Issue.record("Expected a formatted paragraph")
			return
		}
		#expect(runs.contains(text("bold", [.bold])))
		#expect(runs.contains(text("italic", [.italic])))
		#expect(runs.contains(text("gone", [.strikethrough])))
		#expect(runs.contains(text("238 W", [.inlineCode])))
		#expect(runs.contains(text("both", [.bold, .italic])))
		#expect(
			ReplyParser.foundation.document(source).accessibilityText
				== "Heading\n\nbold italic gone 238 W both")
	}

	@Test(arguments: Array(1...6)) func everyHeadingLevelIsBounded(level: Int) throws {
		#expect(
			try blocks(String(repeating: "#", count: level) + " Title") == [
				.heading(try #require(HeadingLevel(rawValue: level)), [text("Title")])
			])
	}

	@Test func nestedListsKeepTheirItemsAndOriginalOrdinals() throws {
		let parsed = try blocks("3. outer\n   - inner\n     1. deep\n   - sibling\n4. last")
		let deep = ReplyBlock.list(
			.ordered(
				NonEmpty(
					first: NumberedItem(
						ordinal: 1, blocks: NonEmpty(first: .paragraph([text("deep")]), rest: [])),
					rest: [])))
		let nested = ReplyBlock.list(
			.unordered(
				NonEmpty(
					first: NonEmpty(first: .paragraph([text("inner")]), rest: [deep]),
					rest: [NonEmpty(first: .paragraph([text("sibling")]), rest: [])])))
		#expect(
			parsed == [
				.list(
					.ordered(
						NonEmpty(
							first: NumberedItem(
								ordinal: 3,
								blocks: NonEmpty(first: .paragraph([text("outer")]), rest: [nested])
							),
							rest: [
								NumberedItem(
									ordinal: 4,
									blocks: NonEmpty(first: .paragraph([text("last")]), rest: []))
							])))
			])
	}

	@Test func softAndHardBreaksStayLineBreaks() throws {
		let document = ReplyParser.foundation.document("first\nsecond  \nthird\\\nfourth")
		_ = try blocks("first\nsecond  \nthird\\\nfourth")
		#expect(document.accessibilityText == "first\nsecond\nthird\nfourth")
	}

	@Test func tableKeepsAlignmentStylesAndEmptyCells() throws {
		let parsed = try blocks(
			"| Day | Load | Note |\n| :--- | ---: | :---: |\n| Tue | **48** | |\n| Thu | 82 | `easy` |"
		)
		guard case .table(let table) = parsed.first else {
			Issue.record("Expected a table")
			return
		}
		#expect(table.columns.elements == [.left, .right, .center])
		#expect(table.header == [[text("Day")], [text("Load")], [text("Note")]])
		#expect(
			table.rows == [
				[[text("Tue")], [text("48", [.bold])], []],
				[[text("Thu")], [text("82")], [text("easy", [.inlineCode])]],
			])
		#expect(parsed.first?.accessibilityText == "Day\tLoad\tNote\nTue\t48\t\nThu\t82\teasy")
	}

	@Test func tableRejectsUnequalWidths() {
		#expect(throws: ReplyParseFailure.documentStructure) {
			try ReplyTable(
				validating: NonEmpty(first: .left, rest: [.right]), header: [[]], rows: [])
		}
		#expect(throws: ReplyParseFailure.documentStructure) {
			try ReplyTable(
				validating: NonEmpty(first: .left, rest: []), header: [[]], rows: [[[], []]])
		}
	}

	@Test func longSharedFixtureRetainsWholeCodeAndBothSafeLinks() throws {
		let source = FormattedReplyFixture.source
		let parsed = try blocks(source)
		let code = parsed.compactMap { block -> String? in
			if case .codeBlock(let text, _) = block { return text }
			return nil
		}
		#expect(source.count > 4_096)
		#expect(code.count == 2)
		#expect(code.last == String(repeating: "238 W Zone 2\n", count: 800))
		let links = parsed.flatMap(allRuns).compactMap { run -> URL? in
			if case .link(_, let target) = run { return target.url }
			return nil
		}
		#expect(
			links.map(\.absoluteString) == [
				"https://www.example.com/threshold-basics", "http://example.com/calendar",
			])
		#expect(parsed.last == .paragraph([text("END FORMATTED REPLY")]))
		#expect(ReplyParser.foundation.document(source) == ReplyParser.foundation.document(source))
	}

	@Test func fixtureDecoderFailureReturnsEverySourceCharacter() {
		let source = FormattedReplyFixture.source
		let document = ReplyParser.failing.document(source)
		#expect(
			document
				== .plainText(
					source: source, failure: .foundation(domain: "ReplyParserFixture", code: 1)))
		#expect(document.accessibilityText == source)
	}

	@Test func decoderErrorIsReportedWithWholeSource() {
		let parser = ReplyParser { _ in throw NSError(domain: "ParserProof", code: 12) }
		#expect(
			parser.document("**whole** [reply](tel:1)")
				== .plainText(
					source: "**whole** [reply](tel:1)",
					failure: .foundation(domain: "ParserProof", code: 12)))
	}

	@Test func emptyAndIncompleteStreamingPrefixesRemainReadable() throws {
		#expect(try blocks("") == [])
		for source in ["**open", "[bad](", "# title\n\n**open [bad](tel:"] {
			let parsed = try blocks(source)
			#expect(!parsed.isEmpty)
		}
		#expect(
			try blocks("```unclosed\ntext") == [.codeBlock(text: "text\n", language: "unclosed")])
	}

	private func blocks(_ source: String) throws -> [ReplyBlock] {
		guard case .blocks(let blocks) = ReplyParser.foundation.document(source) else {
			Issue.record("Expected a reply document for \(source.prefix(80))")
			throw ReplyParseFailure.documentStructure
		}
		return blocks
	}

	private func text(_ value: String, _ styles: Set<InlineStyle> = []) -> ReplyRun {
		.text(StyledText(text: value, styles: styles))
	}

	private func allRuns(_ block: ReplyBlock) -> [ReplyRun] {
		switch block {
		case .paragraph(let runs), .heading(_, let runs): return runs
		case .codeBlock: return []
		case .table(let table): return ([table.header] + table.rows).flatMap { $0.flatMap { $0 } }
		case .list(.ordered(let items)):
			return items.elements.flatMap { $0.blocks.elements.flatMap(allRuns) }
		case .list(.unordered(let items)):
			return items.elements.flatMap { $0.elements.flatMap(allRuns) }
		}
	}
}
