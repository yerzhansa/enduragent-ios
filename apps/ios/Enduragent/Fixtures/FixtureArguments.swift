#if DEBUG
	import Foundation

	enum FixtureStorePolicy: String, CaseIterable {
		case fresh
		case keep
		case unreadable
		case v1History = "v1-history"
		case v1Review = "v1-review"
		case preVault = "pre-vault-5de5c782"

		var upgradeResource: (folder: String?, name: String, device: String)? {
			switch self {
			case .v1History: ("v1-upgrade", "history", "v1-upgrade-fixture")
			case .v1Review: ("v1-upgrade", "review", "v1-upgrade-fixture")
			case .preVault: (nil, rawValue, rawValue)
			case .fresh, .keep, .unreadable: nil
			}
		}
	}

	enum FixtureKeychainPolicy: String {
		case unlocked
		case locked
		case empty
	}

	struct FixtureArguments: Equatable {
		var store: FixtureStorePolicy = .fresh
		var keychain: FixtureKeychainPolicy = .unlocked
		var coalescingMilliseconds: Int?
		var recovery = "readable"
		var host: String?
		var language = "en"
		var locale = "en_US"
		var clock: String?
		var onboarded = false

		var launchArguments: [String] {
			var values = [
				"-EnduragentFixture", "first-week", "-EnduragentFixtureStore", store.rawValue,
				"-EnduragentFixtureKeychain", keychain.rawValue,
				"-EnduragentFixtureRecovery", recovery,
				"-AppleLanguages", "(\(language))", "-AppleLocale", locale,
			]
			if let coalescingMilliseconds {
				values += ["-EnduragentFixtureCoalescing", String(coalescingMilliseconds)]
			}
			if let host { values += ["-EnduragentFixtureHost", host] }
			if let clock { values += ["-EnduragentFixtureClock", clock] }
			if onboarded { values += ["-enduragent.onboardingCompleted", "YES"] }
			return values
		}

		mutating func update(from arguments: [String]) throws {
			guard arguments.count.isMultiple(of: 2) else {
				throw DecodingError.dataCorrupted(
					.init(codingPath: [], debugDescription: "unpaired launch argument"))
			}
			var values: [String: String] = [:]
			for index in stride(from: 0, to: arguments.count, by: 2) {
				values[arguments[index]] = arguments[index + 1]
			}
			store = try policy(values, "-EnduragentFixtureStore", default: FixtureStorePolicy.fresh)
			keychain = try policy(
				values, "-EnduragentFixtureKeychain", default: FixtureKeychainPolicy.unlocked)
			coalescingMilliseconds = try values["-EnduragentFixtureCoalescing"].map { raw in
				guard let value = Int(raw) else {
					throw DecodingError.dataCorrupted(
						.init(codingPath: [], debugDescription: "invalid coalescing window"))
				}
				return value
			}
			recovery = values["-EnduragentFixtureRecovery"] ?? "readable"
			host = values["-EnduragentFixtureHost"]
			language = (values["-AppleLanguages"] ?? "(en)").trimmingCharacters(
				in: CharacterSet(charactersIn: "()"))
			locale = values["-AppleLocale"] ?? "en_US"
			clock = values["-EnduragentFixtureClock"]
			onboarded = values["-enduragent.onboardingCompleted"] == "YES"
		}

		private func policy<Policy: RawRepresentable>(
			_ values: [String: String], _ key: String, default fallback: Policy
		) throws -> Policy where Policy.RawValue == String {
			guard let raw = values[key] else { return fallback }
			guard let value = Policy(rawValue: raw) else {
				throw DecodingError.dataCorrupted(
					.init(codingPath: [], debugDescription: "invalid \(key): \(raw)"))
			}
			return value
		}
	}
#endif
