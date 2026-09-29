import Testing
import UIKit

@testable import Enduragent

@MainActor
struct AccentColorTests {
	@Test(arguments: [
		(UIUserInterfaceStyle.light, 56, 101, 142),
		(UIUserInterfaceStyle.dark, 130, 174, 214),
	])
	func appBundleAccentMatchesAppearance(
		style: UIUserInterfaceStyle, red: Int, green: Int, blue: Int
	) throws {
		let traits = UITraitCollection(userInterfaceStyle: style)
		let asset = try #require(
			UIColor(named: "AccentColor", in: Bundle(for: ShellModel.self), compatibleWith: traits))
		let color = asset.resolvedColor(with: traits)
		var actualRed: CGFloat = 0
		var actualGreen: CGFloat = 0
		var actualBlue: CGFloat = 0
		var alpha: CGFloat = 0
		try #require(
			color.getRed(&actualRed, green: &actualGreen, blue: &actualBlue, alpha: &alpha))
		#expect(abs(actualRed - CGFloat(red) / 255) < 0.000001)
		#expect(abs(actualGreen - CGFloat(green) / 255) < 0.000001)
		#expect(abs(actualBlue - CGFloat(blue) / 255) < 0.000001)
		#expect(alpha == 1)
	}
}
