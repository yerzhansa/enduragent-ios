import Foundation
import Testing

@testable import EnduragentCoach

@Suite struct ReplyFoundationTests {
	@Test func tableIntentsIncludeColumnRowAndCellIdentities() throws {
		let parsed = try decode("| Day | Load |\n| :--- | ---: |\n| Tue | **48** |\n| Thu | 82 |")
		let runs = Array(parsed.runs)
		let first = try #require(runs.first?.presentationIntent?.components)
		#expect(
			first.map(\.kind) == [
				.tableCell(columnIndex: 0), .tableHeaderRow,
				.table(columns: [.init(alignment: .left), .init(alignment: .right)]),
			])
		let row = try #require(runs.dropFirst(2).first?.presentationIntent?.components)
		#expect(
			row.map(\.kind) == [.tableCell(columnIndex: 0), .tableRow(rowIndex: 1), first[2].kind])
		#expect(row[2].identity == first[2].identity)
		#expect(row[1].identity != first[1].identity)
	}

	@Test func nestedListAncestorsAreInnermostFirst() throws {
		let parsed = try decode("3. outer\n   - inner\n     1. deep\n   - sibling\n4. last")
		let runs = Array(parsed.runs)
		let deep = try #require(runs.dropFirst(2).first?.presentationIntent?.components)
		#expect(
			deep.map(\.kind) == [
				.paragraph, .listItem(ordinal: 1), .orderedList, .listItem(ordinal: 1),
				.unorderedList, .listItem(ordinal: 3), .orderedList,
			])
		let outer = try #require(runs.first?.presentationIntent?.components)
		#expect(deep.last?.identity == outer.last?.identity)
		#expect(deep[5].identity == outer[1].identity)
	}

	@Test func inlineIntentsBreaksAndHTMLArePinned() throws {
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

	@Test func linksReportPlainLabelsAndRulesHaveTheirOwnIntent() throws {
		let parsed = try decode("[**call**](tel:1)\n\n---")
		let first = try #require(parsed.runs.first)
		#expect(String(parsed[first.range].characters) == "call")
		#expect(first.link?.absoluteString == "tel:1")
		#expect(first.inlinePresentationIntent == nil)
		#expect(parsed.runs.last?.presentationIntent?.components.first?.kind == .thematicBreak)
		#expect(String(try decode("before [](tel:1) after").characters) == "before  after")
	}

	@Test func longCodeIsCompleteAndIncompleteSyntaxIsAccepted() throws {
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

	private var options: AttributedString.MarkdownParsingOptions {
		.init(interpretedSyntax: .full, failurePolicy: .throwError)
	}

	private func decode(_ source: String) throws -> AttributedString {
		try AttributedString(markdown: source, options: options)
	}
}
