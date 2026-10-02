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

	enum FixtureCalendarSaveFault: String {
		case loseAnswerOnce = "lose-answer-once"
	}

	enum FixtureCalendarReadFault: String {
		case failOnce = "fail-once"
	}

	enum FixtureRecordReadFault: String {
		case failAfterPresentedOnce = "fail-after-presented-once"
	}

	enum FixtureResetFault: String {
		case failBoundary
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
		var calendarSaveFault: FixtureCalendarSaveFault?
		var calendarReadFault: FixtureCalendarReadFault?
		var recordReadFault: FixtureRecordReadFault?
		var resetFault: FixtureResetFault?

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
			if let calendarSaveFault {
				values += ["-EnduragentFixtureCalendarSave", calendarSaveFault.rawValue]
			}
			if let calendarReadFault {
				values += ["-EnduragentFixtureCalendarRead", calendarReadFault.rawValue]
			}
			if let recordReadFault {
				values += ["-EnduragentFixtureRecordRead", recordReadFault.rawValue]
			}
			if let resetFault { values += ["-EnduragentFixtureReset", resetFault.rawValue] }
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
			store = try policy(values, "-EnduragentFixtureStore") ?? .fresh
			keychain = try policy(values, "-EnduragentFixtureKeychain") ?? .unlocked
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
			calendarSaveFault = try policy(values, "-EnduragentFixtureCalendarSave")
			calendarReadFault = try policy(values, "-EnduragentFixtureCalendarRead")
			recordReadFault = try policy(values, "-EnduragentFixtureRecordRead")
			resetFault = try policy(values, "-EnduragentFixtureReset")
		}

		private func policy<Policy: RawRepresentable>(
			_ values: [String: String], _ key: String
		) throws -> Policy? where Policy.RawValue == String {
			guard let raw = values[key] else { return nil }
			guard let value = Policy(rawValue: raw) else {
				throw DecodingError.dataCorrupted(
					.init(codingPath: [], debugDescription: "invalid \(key): \(raw)"))
			}
			return value
		}
	}
#endif
