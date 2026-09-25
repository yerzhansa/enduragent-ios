import Foundation
import Security

public final class FakeSecretStore: SecretStore, @unchecked Sendable {
	private struct Contents: Codable {
		var appAccountToken: UUID
		var openRouterKey: String?
		var intervalsApiKey: String?
		var intervalsOAuthAccess: String?
		var intervalsOAuthRefresh: String?

		var intervalsCredential: IntervalsCredential? {
			get {
				if let intervalsApiKey {
					return .apiKey(intervalsApiKey)
				}
				if let intervalsOAuthAccess, let intervalsOAuthRefresh {
					return .oauth(access: intervalsOAuthAccess, refresh: intervalsOAuthRefresh)
				}
				return nil
			}
			set {
				intervalsApiKey = nil
				intervalsOAuthAccess = nil
				intervalsOAuthRefresh = nil
				switch newValue {
				case .apiKey(let key):
					intervalsApiKey = key
				case .oauth(let access, let refresh):
					intervalsOAuthAccess = access
					intervalsOAuthRefresh = refresh
				case nil:
					break
				}
			}
		}
	}

	public static let fileName = "secrets.json"

	private let lock = NSLock()
	private let file: URL?
	private var contents: Contents
	public var locked = false
	public private(set) var storedOpenRouterKeys = 0

	public init(appAccountToken: UUID? = nil) {
		self.file = nil
		self.contents = Contents(appAccountToken: appAccountToken ?? UUID())
	}

	public init(directory: URL) throws {
		let file = directory.appending(path: Self.fileName)
		self.file = file
		if FileManager.default.fileExists(atPath: file.path) {
			self.contents = try JSONDecoder().decode(Contents.self, from: Data(contentsOf: file))
		} else {
			self.contents = Contents(appAccountToken: UUID())
			try persist()
		}
	}

	public func appAccountToken() throws -> UUID {
		lock.lock()
		defer { lock.unlock() }
		try checkUnlocked()
		return contents.appAccountToken
	}

	public func storeAppAccountToken(_ token: UUID) throws {
		lock.lock()
		defer { lock.unlock() }
		contents.appAccountToken = token
		try persist()
	}

	public func openRouterKey() throws -> String? {
		lock.lock()
		defer { lock.unlock() }
		try checkUnlocked()
		return contents.openRouterKey
	}

	public func storeOpenRouterKey(_ key: String) throws {
		lock.lock()
		defer { lock.unlock() }
		contents.openRouterKey = key
		storedOpenRouterKeys += 1
		try persist()
	}

	public func intervalsCredential() throws -> IntervalsCredential? {
		lock.lock()
		defer { lock.unlock() }
		try checkUnlocked()
		return contents.intervalsCredential
	}

	public func storeIntervalsCredential(_ credential: IntervalsCredential) throws {
		lock.lock()
		defer { lock.unlock() }
		contents.intervalsCredential = credential
		try persist()
	}

	private func checkUnlocked() throws {
		if locked {
			throw KeychainStoreError(status: errSecInteractionNotAllowed)
		}
	}

	private func persist() throws {
		guard let file else { return }
		try JSONEncoder().encode(contents).write(to: file, options: .atomic)
	}
}
