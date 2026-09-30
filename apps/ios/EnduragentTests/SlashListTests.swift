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
		let model = model(try services())
		let actual = try slashImage(SlashListView(model: model), scheme: scheme)
		let reference = VStack(alignment: .leading, spacing: 0) {
			ForEach(SlashCommand.allCases, id: \.self) { command in
				Button {
				} label: {
					VStack(alignment: .leading, spacing: 2) {
						Text(command.rawValue)
						Text(model.phrasebook.say(command.menuTitle, [:]))
							.font(.footnote)
							.foregroundStyle(Color.primary)
					}
				}
				.frame(maxWidth: .infinity, alignment: .leading)
				.padding(.horizontal)
				.padding(.vertical, 10)
			}
		}
		let expected = try slashImage(reference, scheme: scheme)
		try #require(expected.width > 0 && expected.height > 0)
		#expect(actual.width == expected.width)
		#expect(actual.height == expected.height)
		let matchesPrimaryReference = try rgba(actual) == rgba(expected)
		#expect(matchesPrimaryReference)
	}

	private func slashImage(_ content: some View, scheme: ColorScheme) throws -> CGImage {
		let renderer = ImageRenderer(
			content:
				content
				.frame(width: 390)
				.tint(Color.accentColor)
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
