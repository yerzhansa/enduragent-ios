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

	@Test(arguments: [DynamicTypeSize.large, .xxxLarge])
	func aStandardTextSizeKeepsTheValueBesideItsMetric(textSize: DynamicTypeSize) throws {
		let ink = try ink(Self.oneRow, textSize: textSize)
		#expect(ink.linkText.minX > ink.plainText.maxX)
		#expect(ink.linkText.minY < ink.plainText.maxY)
		#expect(ink.plainText.minY < ink.linkText.maxY)
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

	private func ink(_ source: String, textSize: DynamicTypeSize) throws -> ReplyInk {
		let ink = try ReplyInk(
			ReplyRendering.image(
				ReplyView(source: source, parser: .foundation), width: Self.replyWidth,
				textSize: textSize))
		try #require(!ink.linkText.isNull)
		return ink
	}

	private func summarySource() throws -> String {
		try #require(
			NumbersReplyFixture.source.components(separatedBy: "\n\n").first {
				$0.hasPrefix("| Metric")
			})
	}
}
