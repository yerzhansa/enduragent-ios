import EnduragentCoach
import SwiftUI
import Testing

@testable import Enduragent

@MainActor
@Suite struct ReplyHeadingRenderingTests {
	@Test(arguments: ["", "Title "])
	func drawingInlineCodeKeepsHeadingBold(prefix: String) throws {
		var expected = AttributedString(prefix)
		expected.font = .body.bold()
		var code = AttributedString("238 W")
		code.font = .system(.body, design: .monospaced).bold()
		code.backgroundColor = Color.primary.opacity(0.06)
		expected.append(code)
		let actual = try ReplyRendering.image(
			ReplyView(source: "# \(prefix)`238 W`", parser: .foundation))
		let reference = try ReplyRendering.image(
			Text(expected).fixedSize(horizontal: false, vertical: true))
		#expect(actual.width == reference.width)
		#expect(actual.height == reference.height)
		let matches = try ReplyRendering.pixels(actual) == ReplyRendering.pixels(reference)
		#expect(matches, "Inline code must keep the heading's bold font")
	}
}
