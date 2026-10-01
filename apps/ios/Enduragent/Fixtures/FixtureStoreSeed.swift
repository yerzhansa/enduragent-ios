#if DEBUG
	import Foundation

	struct FixtureStoreSeed {
		let synced: Data
		let local: Data

		static func fromArguments(_ arguments: UserDefaults) throws -> FixtureStoreSeed? {
			let synced = arguments.string(forKey: "EnduragentFixtureSyncedSeed")
			let local = arguments.string(forKey: "EnduragentFixtureLocalSeed")
			guard synced != nil || local != nil else { return nil }
			return try FixtureStoreSeed(
				synced: decode(synced, key: "EnduragentFixtureSyncedSeed"),
				local: decode(local, key: "EnduragentFixtureLocalSeed"))
		}

		func install(in directory: URL) throws {
			try synced.write(
				to: directory.appending(path: "synced-records.store"), options: .atomic)
			try local.write(to: directory.appending(path: "local-records.store"), options: .atomic)
		}

		private static func decode(_ raw: String?, key: String) throws -> Data {
			guard let raw, let compressed = Data(base64Encoded: raw) else {
				throw FixtureLaunchError.unknownArgument(key: key, value: "invalid store seed")
			}
			return try (compressed as NSData).decompressed(using: .lzfse) as Data
		}
	}
#endif
