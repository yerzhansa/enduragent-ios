import Foundation

struct FixtureArguments: Equatable {
	enum Key: String, CaseIterable {
		case fixture = "EnduragentFixture"
		case store = "EnduragentFixtureStore"
		case keychain = "EnduragentFixtureKeychain"
		case coalescing = "EnduragentFixtureCoalescing"
		case recovery = "EnduragentFixtureRecovery"
		case host = "EnduragentFixtureHost"
		case clock = "EnduragentFixtureClock"
		case languages = "AppleLanguages"
		case locale = "AppleLocale"
		case onboarded = "enduragent.onboardingCompleted"
		case device = "enduragent.deviceId"
		case syncedSeed = "EnduragentFixtureSyncedSeed"
		case localSeed = "EnduragentFixtureLocalSeed"
	}

	private var values: [Key: String]

	init(store: String = "fresh", language: String = "en", locale: String = "en_US") {
		values = [
			.fixture: "first-week", .store: store, .languages: "(\(language))", .locale: locale,
		]
	}

	init(arguments: [String]) {
		precondition(arguments.count.isMultiple(of: 2), "Fixture arguments must be key/value pairs")
		values = [:]
		for index in stride(from: 0, to: arguments.count, by: 2) {
			guard let key = Key(rawValue: String(arguments[index].dropFirst())) else {
				preconditionFailure("Unknown fixture argument \(arguments[index])")
			}
			values[key] = arguments[index + 1]
		}
	}

	subscript(_ key: Key) -> String? {
		get { values[key] }
		set { values[key] = newValue }
	}

	var arguments: [String] {
		Key.allCases.flatMap { key in values[key].map { ["-\(key.rawValue)", $0] } ?? [] }
	}

	mutating func seed(_ scenario: String, in bundle: Bundle) throws {
		for (key, name) in [(Key.syncedSeed, "synced"), (.localSeed, "local")] {
			guard
				let resource = bundle.url(
					forResource: "\(name)-records", withExtension: "store",
					subdirectory: "v1-upgrade/\(scenario)")
			else {
				throw CocoaError(.fileNoSuchFile)
			}
			let data = try NSData(contentsOf: resource, options: [])
			self[key] = try data.compressed(using: .lzfse).base64EncodedString()
		}
		self[.store] = "fresh"
		self[.onboarded] = "YES"
		self[.device] = "v1-upgrade-proof"
	}
}
