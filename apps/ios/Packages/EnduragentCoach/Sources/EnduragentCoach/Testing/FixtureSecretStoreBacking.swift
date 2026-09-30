import Foundation
import Security

extension ICloudKeychainStore {
	public static func fixture(directory: URL) throws
		-> (store: ICloudKeychainStore, backing: FixtureSecretStoreBacking)
	{
		let backing = try FixtureSecretStoreBacking(directory: directory)
		return (ICloudKeychainStore(backing: backing), backing)
	}
}

public final class FixtureSecretStoreBacking: SecretStoreBacking, @unchecked Sendable {
	package static let fileName = "secrets.json"

	private let lock = NSLock()
	private let file: URL?
	private var items: [String: Data]
	private var isLocked = false
	private var failsNextWrite = false
	private var copied: [String] = []
	private var deleted: [String] = []
	private var written: [String: Int] = [:]
	private var failures: [String: OSStatus] = [:]
	private var writeFailures: [String: OSStatus] = [:]

	public var locked: Bool {
		get { lock.withLock { isLocked } }
		set { lock.withLock { isLocked = newValue } }
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
			self.items = try JSONDecoder().decode([String: Data].self, from: Data(contentsOf: file))
		} else {
			self.items = [:]
		}
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
				throw KeychainStoreError(status: errSecDuplicateItem)
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
				throw KeychainStoreError(status: errSecItemNotFound)
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
			throw KeychainStoreError(status: errSecInteractionNotAllowed)
		}
		if let status = failures[account] ?? (writing ? writeFailures[account] : nil) {
			throw KeychainStoreError(status: status)
		}
		if writing && failsNextWrite {
			failsNextWrite = false
			throw KeychainStoreError(status: errSecNotAvailable)
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
