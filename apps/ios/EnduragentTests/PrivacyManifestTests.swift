import Foundation
import Testing

@testable import Enduragent

@Suite struct PrivacyManifestTests {
	@Test
	func theAppBundleHoldsThePrivacyManifest() throws {
		let url = try #require(
			Bundle(for: ShellModel.self).url(forResource: "PrivacyInfo", withExtension: "xcprivacy")
		)
		let manifest = try #require(
			try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil)
				as? [String: Any])
		#expect(manifest["NSPrivacyTracking"] as? Bool == false)
	}
}
