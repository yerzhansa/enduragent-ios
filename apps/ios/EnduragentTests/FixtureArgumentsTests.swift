import EnduragentCoach
import Foundation
import Testing

@testable import Enduragent

@Suite struct FixtureArgumentsTests {
	@Test(arguments: FixtureStorePolicy.allCases)
	func builderRoundTripsThroughTheAppParser(store: FixtureStorePolicy) throws {
		let expected = FixtureArguments(
			store: store, keychain: .locked, coalescingMilliseconds: 1,
			recovery: "unreadable", host: "expire-after 3", language: "de", locale: "de_DE",
			clock: "1998-06-16T07:00:00Z", onboarded: true)
		var restored = FixtureArguments()
		try restored.update(from: expected.launchArguments)
		#expect(restored == expected)
		let otherSuite = "enduragent.fixture.arguments.other.\(UUID().uuidString)"
		let otherDefaults = try #require(UserDefaults(suiteName: otherSuite))
		defer { otherDefaults.removePersistentDomain(forName: otherSuite) }
		otherDefaults.setPersistentDomain(
			[
				FixtureLaunch.clockArgumentKey: FixtureLaunch.defaultClock,
				FixtureLaunch.coalescingArgumentKey: "2000",
				FixtureLaunch.recoveryArgumentKey: "readable",
				"enduragent.onboardingCompleted": false,
			], forName: otherSuite)
		let defaults = try #require(UserDefaults(suiteName: "enduragent.fixture.arguments.test"))
		var values: [String: String] = [:]
		for index in stride(from: 0, to: expected.launchArguments.count, by: 2) {
			values[String(expected.launchArguments[index].dropFirst())] =
				expected.launchArguments[index + 1]
		}
		defaults.setVolatileDomain(values, forName: UserDefaults.argumentDomain)
		let parsed = try #require(try FixtureLaunch.fromArguments(defaults))
		#expect(parsed.name == FixtureLaunch.firstWeekName)
		#expect(parsed.store.rawValue == store.rawValue)
		#expect(parsed.keychain == .locked)
		#expect(parsed.coalescing == CoalescingPolicy(window: .milliseconds(1)))
		#expect(parsed.recovery == .unreadable)
		#expect(parsed.host == .expireAfter(.seconds(3)))
		#expect(parsed.clock == expected.clock)
		#expect(
			otherDefaults.string(forKey: FixtureLaunch.clockArgumentKey)
				== FixtureLaunch.defaultClock)
		#expect(otherDefaults.string(forKey: FixtureLaunch.coalescingArgumentKey) == "2000")
		#expect(otherDefaults.string(forKey: FixtureLaunch.recoveryArgumentKey) == "readable")
		#expect(otherDefaults.bool(forKey: "enduragent.onboardingCompleted") == false)
	}

	@Test func relaunchPreservesOverridesAndReplacesStorePolicy() throws {
		var arguments = FixtureArguments(
			store: .v1Review, keychain: .empty, coalescingMilliseconds: 1,
			host: "expire-after 3", clock: "1998-06-16T07:00:00Z", onboarded: true)
		var kept = FixtureArguments()
		try kept.update(from: arguments.launchArguments)
		kept.store = .keep
		kept.language = "de"
		kept.locale = "de_DE"
		arguments.store = .keep
		arguments.language = "de"
		arguments.locale = "de_DE"
		#expect(kept == arguments)
	}
}
