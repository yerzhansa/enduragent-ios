import Testing
import UIKit

@testable import Enduragent

@MainActor
struct AccentColorTests {
	@Test(arguments: [
		(UIUserInterfaceStyle.light, UIAccessibilityContrast.normal, 56, 101, 142),
		(UIUserInterfaceStyle.dark, UIAccessibilityContrast.normal, 130, 174, 214),
		(UIUserInterfaceStyle.light, UIAccessibilityContrast.high, 51, 92, 130),
		(UIUserInterfaceStyle.dark, UIAccessibilityContrast.high, 171, 201, 227),
	])
	func appBundleAccentMatchesAppearance(
		style: UIUserInterfaceStyle, contrast: UIAccessibilityContrast,
		red: Int, green: Int, blue: Int
	) throws {
		let traits = UITraitCollection {
			$0.userInterfaceStyle = style
			$0.accessibilityContrast = contrast
		}
		let asset = try #require(
			UIColor(named: "AccentColor", in: Bundle(for: ShellModel.self), compatibleWith: traits))
		try expectColor(asset.resolvedColor(with: traits), red: red, green: green, blue: blue)
	}

	@Test
	func appDeclaresGlobalAccent() {
		#expect(
			Bundle.main.object(forInfoDictionaryKey: "NSAccentColorName") as? String
				== "AccentColor")
	}

	private func expectColor(_ color: UIColor, red: Int, green: Int, blue: Int) throws {
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
