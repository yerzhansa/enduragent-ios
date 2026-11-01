import CoreGraphics
import SwiftUI
import Testing

@MainActor
enum ReplyRendering {
	static func image(
		_ content: some View, width: CGFloat = 390, textSize: DynamicTypeSize = .medium,
		region: String = "en_US"
	) throws -> CGImage {
		let renderer = ImageRenderer(
			content:
				content
				.frame(maxWidth: .infinity, alignment: .leading)
				.frame(width: width)
				.font(.body)
				.dynamicTypeSize(textSize)
				.environment(\.locale, Locale(identifier: region))
				.environment(\.colorScheme, .light)
				.foregroundStyle(.primary)
				.background(Color.white))
		renderer.scale = 1
		return try #require(renderer.cgImage)
	}

	static func pixels(_ image: CGImage) throws -> [UInt8] {
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

@MainActor
struct ReplyInk {
	private(set) var plainText = CGRect.null
	private(set) var linkText = CGRect.null

	init(_ image: CGImage) throws {
		let bytes = try ReplyRendering.pixels(image)
		for row in 0..<image.height {
			for column in 0..<image.width {
				let start = (row * image.width + column) * 4
				let channels = bytes[start..<start + 3]
				let strongest = Int(try #require(channels.max()))
				let tint = strongest - Int(try #require(channels.min()))
				let pixel = CGRect(x: column, y: row, width: 1, height: 1)
				if tint >= 40 { linkText = linkText.union(pixel) }
				if strongest <= 60 { plainText = plainText.union(pixel) }
			}
		}
	}
}
