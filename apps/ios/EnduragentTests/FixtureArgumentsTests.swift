import EnduragentCoach
import Foundation
import Testing

@testable import Enduragent

@MainActor
@Suite struct FixtureArgumentsTests {
	@Test func builderRoundTripsEveryLaunchOption() throws {
		var fixture = FixtureArguments(store: "keep", language: "de", locale: "de_DE")
		fixture[.keychain] = "locked"
		fixture[.coalescing] = "2000"
		fixture[.recovery] = "unreadable"
		fixture[.host] = "expire-after 3"
		fixture[.clock] = "1998-06-16T08:00:00Z"
		#expect(FixtureArguments(arguments: fixture.arguments) == fixture)
		let arguments = try defaults(fixture)
		let launch = try #require(try FixtureLaunch.fromArguments(arguments))
		#expect(launch.name == FixtureLaunch.firstWeekName)
		#expect(launch.store == .keep)
		#expect(launch.keychain == .locked)
		#expect(launch.coalescing == CoalescingPolicy(window: .milliseconds(2000)))
		#expect(launch.recovery == .unreadable)
		#expect(launch.host == .expireAfter(.seconds(3)))
		#expect(launch.clock == "1998-06-16T08:00:00Z")
		#expect(arguments.string(forKey: "AppleLanguages") == "(de)")
		#expect(arguments.string(forKey: "AppleLocale") == "de_DE")
	}

	@Test(arguments: ["history", "review"])
	func upgradeLaunchCopiesCommittedStores(scenario: String) throws {
		var fixture = FixtureArguments()
		try fixture.seed(scenario, in: Bundle(for: FixtureResourceBundle.self))
		#expect(FixtureArguments(arguments: fixture.arguments) == fixture)
		let arguments = try defaults(fixture)
		var launch = try #require(try FixtureLaunch.fromArguments(arguments))
		launch.directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
		launch.defaultsSuiteName = UUID().uuidString
		defer {
			do { try FileManager.default.removeItem(at: launch.directory) } catch {
				Issue.record(error)
			}
		}
		_ = try launch.prepare()
		for name in ["synced", "local"] {
			let source = try #require(
				Bundle(for: FixtureResourceBundle.self).url(
					forResource: "\(name)-records", withExtension: "store",
					subdirectory: "v1-upgrade/\(scenario)"))
			#expect(
				try Data(contentsOf: launch.directory.appending(path: "\(name)-records.store"))
					== Data(contentsOf: source))
		}
		#expect(arguments.bool(forKey: ShellModel.onboardingCompletedKey))
		#expect(arguments.string(forKey: AppServices.deviceDefaultsKey) == "v1-upgrade-proof")
	}

	@Test func incompleteSeedFailsLaunch() throws {
		var fixture = FixtureArguments()
		fixture[.syncedSeed] = "invalid"
		#expect(throws: FixtureLaunchError.self) {
			try FixtureLaunch.fromArguments(defaults(fixture))
		}
	}

	private func defaults(_ fixture: FixtureArguments) throws -> UserDefaults {
		let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
		let arguments = fixture.arguments
		let domain = Dictionary(
			uniqueKeysWithValues: stride(from: 0, to: arguments.count, by: 2).map {
				(String(arguments[$0].dropFirst()), arguments[$0 + 1])
			})
		defaults.setVolatileDomain(domain, forName: UserDefaults.argumentDomain)
		return defaults
	}
}

private final class FixtureResourceBundle: NSObject {}
