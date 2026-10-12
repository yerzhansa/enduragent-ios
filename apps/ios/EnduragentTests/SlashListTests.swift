import EnduragentCoach
import SwiftUI
import Testing

@testable import Enduragent

struct SlashListTests {
	@Test func startIsListedWithItsMenuTitleAndPlanIsGone() {
		let phrasebook = CatalogPhrasebook(tag: .en)
		let rows = SlashCommand.allCases.map { ($0.rawValue, phrasebook.say($0.menuTitle, [:])) }
		#expect(rows.map(\.0) == ["/start", "/workout", "/status", "/review", "/language"])
		#expect(rows.first?.1 == "Start a fresh session")
		#expect(!rows.map(\.0).contains("/plan"))
		#expect(rows.allSatisfy { !$0.1.isEmpty })
	}
}

extension FixtureLaunchTests {
	@Test(arguments: [ColorScheme.light, .dark])
	func slashDescriptionsIgnoreTint(scheme: ColorScheme) async throws {
		let model = await model(try services())
		let red = try slashImage(
			SlashListView(model: model), tint: Color(.sRGB, red: 1, green: 0, blue: 0),
			scheme: scheme)
		let green = try slashImage(
			SlashListView(model: model), tint: Color(.sRGB, red: 0, green: 1, blue: 0),
			scheme: scheme)
		try #require(red.width > 0 && red.height > 0)
		try #require(red.width == green.width && red.height == green.height)
		let redPixels = try rgba(red)
		let greenPixels = try rgba(green)
		let background: UInt8 = scheme == .light ? 255 : 0
		let unchangedForeground = stride(from: 0, to: redPixels.count, by: 4).filter { offset in
			redPixels[offset..<offset + 4] == greenPixels[offset..<offset + 4]
				&& (redPixels[offset] != background || redPixels[offset + 1] != background
					|| redPixels[offset + 2] != background)
		}
		try #require(!unchangedForeground.isEmpty)
		#expect(
			unchangedForeground.allSatisfy { offset in
				redPixels[offset] == redPixels[offset + 1]
					&& redPixels[offset + 1] == redPixels[offset + 2]
			})
	}

	private func slashImage(_ content: some View, tint: Color, scheme: ColorScheme) throws
		-> CGImage
	{
		let renderer = ImageRenderer(
			content:
				content
				.frame(width: 390)
				.tint(tint)
				.font(.body)
				.dynamicTypeSize(.medium)
				.environment(\.colorScheme, scheme)
				.background(scheme == .light ? Color.white : Color.black))
		renderer.scale = 1
		return try #require(renderer.cgImage)
	}

	private func rgba(_ image: CGImage) throws -> [UInt8] {
		let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
		var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
		try pixels.withUnsafeMutableBytes { buffer in
			let context = try #require(
				CGContext(
					data: buffer.baseAddress, width: image.width, height: image.height,
					bitsPerComponent: 8, bytesPerRow: image.width * 4, space: space,
					bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
			context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
		}
		return pixels
	}
}
