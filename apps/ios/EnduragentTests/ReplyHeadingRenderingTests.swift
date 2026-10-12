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
		let actual = try image(
			ReplyView(source: "# \(prefix)`238 W`", parser: .foundation))
		let reference = try image(Text(expected).fixedSize(horizontal: false, vertical: true))
		#expect(actual.width == reference.width)
		#expect(actual.height == reference.height)
		let matches = try pixels(actual) == pixels(reference)
		#expect(matches, "Inline code must keep the heading's bold font")
	}

	private func image(_ content: some View) throws -> CGImage {
		let renderer = ImageRenderer(
			content:
				content
				.frame(maxWidth: .infinity, alignment: .leading)
				.frame(width: 390)
				.font(.body)
				.dynamicTypeSize(.medium)
				.environment(\.colorScheme, .light)
				.foregroundStyle(.primary)
				.background(Color.white))
		renderer.scale = 1
		return try #require(renderer.cgImage)
	}

	private func pixels(_ image: CGImage) throws -> [UInt8] {
		let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
		var result = [UInt8](repeating: 0, count: image.width * image.height * 4)
		try result.withUnsafeMutableBytes { buffer in
			let context = try #require(
				CGContext(
					data: buffer.baseAddress, width: image.width, height: image.height,
					bitsPerComponent: 8, bytesPerRow: image.width * 4, space: space,
					bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
			context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
		}
		return result
	}
}
