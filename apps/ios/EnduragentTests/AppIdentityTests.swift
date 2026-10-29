import EnduragentCoach
import Foundation
import Testing

@Suite struct AppIdentityTests {
	static let keys = ["CFBundleDisplayName", "CFBundleShortVersionString", "CFBundleVersion"]

	static func infoDictionary() -> [String: Any] {
		[
			"CFBundleDisplayName": "Enduragent", "CFBundleShortVersionString": "0.1.0",
			"CFBundleVersion": "3", "CFBundleIdentifier": "icu.enduragent.ios",
		]
	}

	@Test func readsNameVersionAndBuild() throws {
		let identity = try AppIdentity(infoDictionary: Self.infoDictionary())
		#expect(identity.name == "Enduragent")
		#expect(identity.version == "0.1.0")
		#expect(identity.build == "3")
	}

	@Test(arguments: keys)
	func aMissingKeyIsNamed(_ key: String) {
		var dictionary = Self.infoDictionary()
		dictionary[key] = nil
		#expect(throws: AppIdentityFailure.missing(key)) {
			try AppIdentity(infoDictionary: dictionary)
		}
	}

	@Test(arguments: keys)
	func aNonStringValueIsNamed(_ key: String) {
		var dictionary = Self.infoDictionary()
		dictionary[key] = 3
		#expect(throws: AppIdentityFailure.malformed(key)) {
			try AppIdentity(infoDictionary: dictionary)
		}
	}

	@Test func theAppBundleHasAllThree() throws {
		let identity = try AppIdentity(infoDictionary: #require(Bundle.main.infoDictionary))
		#expect(identity.name == "Enduragent")
	}
}
