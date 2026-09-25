import Foundation

enum FixtureStorePolicy: String {
	case fresh
	case keep
}

enum FixtureKeychainPolicy: String {
	case unlocked
	case locked
}

enum FixtureLaunchError: Error {
	case unknownFixture(String)
	case unknownArgument(key: String, value: String)
	case defaultsSuiteUnavailable(String)
}

struct FixtureLaunch {
	static let nameArgumentKey = "EnduragentFixture"
	static let storeArgumentKey = "EnduragentFixtureStore"
	static let keychainArgumentKey = "EnduragentFixtureKeychain"
	static let firstWeekName = "first-week"
	static let defaultsSuiteName = "icu.enduragent.fixture"
	static let directoryName = "fixture"

	var name: String
	var store: FixtureStorePolicy
	var keychain: FixtureKeychainPolicy
	var directory: URL
	var defaultsSuiteName: String

	static func fromArguments(_ arguments: UserDefaults = .standard) throws -> FixtureLaunch? {
		guard let name = arguments.string(forKey: nameArgumentKey) else { return nil }
		return FixtureLaunch(
			name: name,
			store: try policy(arguments, key: storeArgumentKey) ?? .fresh,
			keychain: try policy(arguments, key: keychainArgumentKey) ?? .unlocked,
			directory: try applicationSupportDirectory(),
			defaultsSuiteName: defaultsSuiteName
		)
	}

	static func firstWeek() throws -> FixtureLaunch {
		FixtureLaunch(
			name: firstWeekName,
			store: .fresh,
			keychain: .unlocked,
			directory: try applicationSupportDirectory(),
			defaultsSuiteName: defaultsSuiteName
		)
	}

	func prepare() throws -> UserDefaults {
		guard let defaults = UserDefaults(suiteName: defaultsSuiteName) else {
			throw FixtureLaunchError.defaultsSuiteUnavailable(defaultsSuiteName)
		}
		let files = FileManager.default
		if store == .fresh {
			defaults.removePersistentDomain(forName: defaultsSuiteName)
			if files.fileExists(atPath: directory.path) {
				try files.removeItem(at: directory)
			}
		}
		try files.createDirectory(at: directory, withIntermediateDirectories: true)
		return defaults
	}

	private static func policy<Policy: RawRepresentable>(
		_ arguments: UserDefaults, key: String
	) throws -> Policy? where Policy.RawValue == String {
		guard let raw = arguments.string(forKey: key) else { return nil }
		guard let policy = Policy(rawValue: raw) else {
			throw FixtureLaunchError.unknownArgument(key: key, value: raw)
		}
		return policy
	}

	private static func applicationSupportDirectory() throws -> URL {
		let root = try FileManager.default.url(
			for: .applicationSupportDirectory,
			in: .userDomainMask,
			appropriateFor: nil,
			create: true
		)
		return root.appending(path: directoryName, directoryHint: .isDirectory)
	}
}
