import EnduragentCoach
import SwiftUI
import Testing

@testable import Enduragent

struct SlashListTests {
	@Test func startIsListedWithItsMenuTitleAndPlanIsGone() {
		let phrasebook = CatalogPhrasebook(tag: .en, locale: "en")
		let rows = SlashCommand.allCases.map { ($0.rawValue, phrasebook.say($0.menuTitle, [:])) }
		#expect(rows.map(\.0) == ["/start", "/workout", "/status", "/review", "/language"])
		#expect(rows.first?.1 == "Start a fresh session")
		#expect(!rows.map(\.0).contains("/plan"))
		#expect(rows.allSatisfy { !$0.1.isEmpty })
	}
}

extension FixtureLaunchTests {
	@Test(arguments: [ColorScheme.light, .dark])
	func slashDescriptionsRenderInPrimaryTextColor(scheme: ColorScheme) throws {
		let content = SlashListView(model: model(try services()))
			.frame(width: 390)
			.tint(Color.accentColor)
			.environment(\.colorScheme, scheme)
			.background(scheme == .light ? Color.white : Color.black)
		let image = try #require(ImageRenderer(content: content).cgImage)
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
		let expected: UInt8 = scheme == .light ? 0 : 255
		let primary: [UInt8] = [expected, expected, expected, 255]
		let primaryPixels = stride(from: 0, to: pixels.count, by: 4).filter { index in
			pixels[index..<index + 4].elementsEqual(primary)
		}
		#expect(primaryPixels.count > 100)
	}
}
