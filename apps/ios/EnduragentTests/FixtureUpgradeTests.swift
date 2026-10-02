import EnduragentCoach
import EnduragentCoachFixtures
import Foundation
import Testing

@testable import Enduragent

@MainActor
@Suite(FixtureTestScope()) struct FixtureUpgradeTests {
	@Test func preVaultPolicyCopiesTheCommittedStoreAndSeedsTheLegacyKey() throws {
		let store = try #require(FixtureStorePolicy(rawValue: "pre-vault-5de5c782"))
		var launch = AppTestFixture.active.launch
		launch.store = store
		let defaults = try launch.prepare()
		let source = try #require(Bundle.main.url(forResource: store.rawValue, withExtension: nil))
		for name in ["synced-records.store", "local-records.store"] {
			#expect(
				try Data(contentsOf: launch.directory.appending(path: name))
					== Data(contentsOf: source.appending(path: name)))
		}
		#expect(defaults.string(forKey: AppServices.deviceDefaultsKey) == "pre-vault-5de5c782")
		#expect(defaults.bool(forKey: ShellModel.onboardingCompletedKey))
		#expect(
			try String(
				contentsOf: launch.directory.appending(path: "secrets.json"), encoding: .utf8)
				== #"{"intervalsApiKey":"fixture-pre-vault-key"}"#)
		let secrets = try ICloudKeychainStore.fixture(directory: launch.directory).store
		#expect(try secrets.intervalsConnection()?.credential == .apiKey("fixture-pre-vault-key"))
		#expect(try secrets.intervalsConnection()?.selection == .keyOwner)
		#expect(try secrets.intervalsConnection()?.resolvedAthlete == nil)
	}
}
