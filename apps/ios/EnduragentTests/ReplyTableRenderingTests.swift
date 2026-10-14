import EnduragentCoach
import EnduragentCoachFixtures
import SwiftUI
import Testing

@testable import Enduragent

@MainActor
@Suite struct ReplyTableRenderingTests {
	private static let replyWidth: CGFloat = 358
	private static let link = "https://example.com"
	private static let oneRow = "| Metric | Value |\n|---|---:|\n| Distance | [42.5 km](\(link)) |"

	@Test(arguments: [DynamicTypeSize.accessibility1, .accessibility5])
	func anAccessibilityTextSizePutsTheValueUnderItsMetric(textSize: DynamicTypeSize) throws {
		let ink = try ink(Self.oneRow, textSize: textSize)
		#expect(ink.linkText.minY >= ink.plainText.maxY)
		#expect(ink.linkText.minX < ink.plainText.maxX)
	}

	@Test(arguments: [DynamicTypeSize.large, .xxxLarge])
	func aStandardTextSizeKeepsTheValueBesideItsMetric(textSize: DynamicTypeSize) throws {
		let ink = try ink(Self.oneRow, textSize: textSize)
		#expect(ink.linkText.minX > ink.plainText.maxX)
		#expect(ink.linkText.minY < ink.plainText.maxY)
		#expect(ink.plainText.minY < ink.linkText.maxY)
	}

	@Test func everySummaryCellIsDrawnInFullAtTheLargestTextSize() throws {
		let summary = try summaryTable()
		let lines = [summary.headerDescription] + summary.rowDescriptions
		let linked =
			lines.map { line in
				"| " + line.parts.map { "[\($0)](\(Self.link))" }.joined(separator: " | ") + " |"
			}
		let source = ([linked[0], "|---|---:|"] + linked.dropFirst()).joined(separator: "\n")
		let drawn = try #require(table(source))
		try #require(drawn.rowDescriptions.map(\.parts) == summary.rowDescriptions.map(\.parts))
		let onThePhone = try ink(source, textSize: .accessibility5)
		let unconstrained = try ink(source, textSize: .accessibility5, width: 1400)
		try #require(unconstrained.linkAmount > 0)
		let difference = abs(unconstrained.linkAmount - onThePhone.linkAmount)
		#expect(difference * 100 < unconstrained.linkAmount)
	}

	@Test(arguments: ["de_DE", "pt_PT", "zh_Hant_TW"])
	func theSummaryTableIsDrawnTheSameInEveryRegion(region: String) throws {
		let source = try summarySource()
		let reply = ReplyView(source: source, parser: .foundation)
		let english = try ReplyRendering.image(
			reply, width: Self.replyWidth, textSize: .accessibility5)
		let regional = try ReplyRendering.image(
			reply, width: Self.replyWidth, textSize: .accessibility5, region: region)
		#expect(regional.width == english.width)
		#expect(regional.height == english.height)
		let matches = try ReplyRendering.pixels(regional) == ReplyRendering.pixels(english)
		#expect(matches, "The region \(region) must not change a character of the table")
	}

	private func ink(
		_ source: String, textSize: DynamicTypeSize, width: CGFloat = replyWidth
	) throws -> ReplyInk {
		let ink = try ReplyInk(
			ReplyRendering.image(
				ReplyView(source: source, parser: .foundation), width: width, textSize: textSize))
		try #require(!ink.linkText.isNull)
		return ink
	}

	private func summarySource() throws -> String {
		try #require(
			NumbersReplyFixture.source.components(separatedBy: "\n\n").first {
				$0.hasPrefix("| Metric")
			})
	}

	private func summaryTable() throws -> ReplyTable {
		let summary = try #require(table(try summarySource()))
		try #require(summary.layout == .stacked)
		return summary
	}

	private func table(_ source: String) -> ReplyTable? {
		guard case .blocks(let blocks) = ReplyParser.foundation.document(source),
			case .table(let table) = blocks.first
		else { return nil }
		return table
	}
}
