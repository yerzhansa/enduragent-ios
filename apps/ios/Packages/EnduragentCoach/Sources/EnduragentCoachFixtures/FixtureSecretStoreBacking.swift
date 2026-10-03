import EnduragentCoach
import Foundation
import Security

extension ICloudKeychainStore {
	public static func fixture(directory: URL) throws
		-> (store: ICloudKeychainStore, backing: FixtureSecretStoreBacking)
	{
		let backing = try FixtureSecretStoreBacking(directory: directory)
		return (backing.store(), backing)
	}
}

public final class FixtureSecretStoreBacking: SecretStoreBacking, @unchecked Sendable {
	package static let fileName = "secrets.json"

	private let lock = NSLock()
	private let file: URL?
	private var items: [String: Data]
	private var isLocked = false
	private var isUnavailable = false
	private var failsNextWrite = false
	private var copied: [String] = []
	private var deleted: [String] = []
	private var written: [String: Int] = [:]
	private var failures: [String: OSStatus] = [:]
	private var writeFailures: [String: OSStatus] = [:]

	public func store() -> ICloudKeychainStore {
		ICloudKeychainStore(backing: self)
	}

	public var locked: Bool {
		get { lock.withLock { isLocked } }
		set { lock.withLock { isLocked = newValue } }
	}

	public var unavailable: Bool {
		get { lock.withLock { isUnavailable } }
		set { lock.withLock { isUnavailable = newValue } }
	}

	public func corruptIntervalsConnection() throws {
		try lock.withLock {
			let account = CredentialSlot.intervalsConnection.rawValue
			try check(account, writing: true)
			try persist(account: account, data: Data("fixture-malformed-secret".utf8))
		}
	}

	public func corruptAccessSelection() throws {
		try lock.withLock {
			let account = CredentialSlot.accessSelection.rawValue
			try check(account, writing: true)
			try persist(account: account, data: Data("fixture-malformed-selection".utf8))
		}
	}

	public var failNextWrite: Bool {
		get { lock.withLock { failsNextWrite } }
		set { lock.withLock { failsNextWrite = newValue } }
	}

	package var readCount: Int { lock.withLock { copied.count } }
	package var readAccounts: [String] { lock.withLock { copied } }
	package var deletedAccounts: [String] { lock.withLock { deleted } }
	package var writeCount: Int { lock.withLock { written.values.reduce(0, +) } }

	package init(items: [String: Data] = [:]) {
		self.file = nil
		self.items = items
	}

	fileprivate init(directory: URL) throws {
		let file = directory.appending(path: Self.fileName)
		self.file = file
		if FileManager.default.fileExists(atPath: file.path) {
			self.items = try Self.readItems(Data(contentsOf: file))
		} else {
			self.items = [:]
		}
	}

	private static func readItems(_ data: Data) throws -> [String: Data] {
		guard let fields = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
			throw KeychainStoreError.keychain(errSecDecode)
		}
		let legacyNames: Set<String> = [
			"intervals", "intervalsApiKey", "intervalsOAuthAccess",
			"intervalsOAuthRefresh",
		]
		if legacyNames.isDisjoint(with: fields.keys),
			fields.values.allSatisfy({ ($0 as? String).flatMap { Data(base64Encoded: $0) } != nil })
		{
			return try JSONDecoder().decode([String: Data].self, from: data)
		}
		var items: [String: Data] = [:]
		for name in ["appAccountToken", "openRouterKey", "openRouterAccountKey"] {
			guard let value = fields[name], !(value is NSNull) else { continue }
			guard let string = value as? String else {
				throw KeychainStoreError.keychain(errSecDecode)
			}
			items[name] = Data(string.utf8)
		}
		for (name, account) in [
			("creditsAccount", CredentialSlot.creditsAccount.rawValue),
			("intervals", CredentialSlot.intervalsConnection.rawValue),
			("accessSelection", CredentialSlot.accessSelection.rawValue),
		] {
			guard let value = fields[name], !(value is NSNull) else { continue }
			items[account] = try JSONSerialization.data(
				withJSONObject: value, options: .fragmentsAllowed)
		}
		if items[CredentialSlot.intervalsConnection.rawValue] == nil {
			let credential: [String: Any]
			if let key = fields["intervalsApiKey"], !(key is NSNull) {
				credential = ["apiKey": ["_0": key]]
			} else if let access = fields["intervalsOAuthAccess"], !(access is NSNull),
				let refresh = fields["intervalsOAuthRefresh"], !(refresh is NSNull)
			{
				credential = ["oauth": ["access": access, "refresh": refresh]]
			} else {
				return items
			}
			items[CredentialSlot.intervalsConnection.rawValue] = try JSONSerialization.data(
				withJSONObject: credential)
		}
		return items
	}

	package func fail(_ account: String, with status: OSStatus?) {
		lock.withLock { failures[account] = status }
	}

	package func failWrites(_ account: String, with status: OSStatus?) {
		lock.withLock { writeFailures[account] = status }
	}

	package func writes(to account: String) -> Int {
		lock.withLock { written[account, default: 0] }
	}

	package func add(account: String, data: Data) throws {
		try lock.withLock {
			try check(account, writing: true)
			guard items[account] == nil else {
				throw KeychainStoreError.keychain(errSecDuplicateItem)
			}
			try persist(account: account, data: data)
			written[account, default: 0] += 1
		}
	}

	package func copy(account: String) throws -> Data? {
		try lock.withLock {
			copied.append(account)
			try check(account)
			return items[account]
		}
	}

	package func update(account: String, data: Data) throws {
		try lock.withLock {
			try check(account, writing: true)
			guard items[account] != nil else {
				throw KeychainStoreError.keychain(errSecItemNotFound)
			}
			try persist(account: account, data: data)
			written[account, default: 0] += 1
		}
	}

	package func delete(account: String) throws {
		try lock.withLock {
			try check(account)
			if items[account] != nil {
				try check(account, writing: true)
				try persist(account: account, data: nil)
			}
			deleted.append(account)
		}
	}

	private func check(_ account: String, writing: Bool = false) throws {
		if isLocked {
			throw KeychainStoreError.keychain(errSecInteractionNotAllowed)
		}
		if isUnavailable {
			throw KeychainStoreError.keychain(errSecNotAvailable)
		}
		let slot = account.split(separator: "/").first.map(String.init) ?? account
		if let status = failures[account] ?? failures[slot]
			?? (writing ? writeFailures[account] ?? writeFailures[slot] : nil)
		{
			throw KeychainStoreError.keychain(status)
		}
		if writing && failsNextWrite {
			failsNextWrite = false
			throw KeychainStoreError.keychain(errSecNotAvailable)
		}
	}

	private func persist(account: String, data: Data?) throws {
		var replacement = items
		replacement[account] = data
		if let file {
			try JSONEncoder().encode(replacement).write(to: file, options: .atomic)
		}
		items = replacement
	}
}
