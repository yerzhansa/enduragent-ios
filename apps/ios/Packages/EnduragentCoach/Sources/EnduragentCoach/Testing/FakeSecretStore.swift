import Foundation

public final class FakeSecretStore: SecretStore, @unchecked Sendable {
	private let lock = NSLock()
	private var token: UUID
	private var openRouter: String?
	private var intervals: IntervalsCredential?
	public private(set) var storedOpenRouterKeys = 0

	public init(appAccountToken: UUID? = nil) {
		self.token = appAccountToken ?? UUID()
	}

	public func appAccountToken() throws -> UUID {
		lock.lock()
		defer { lock.unlock() }
		return token
	}

	public func storeAppAccountToken(_ token: UUID) throws {
		lock.lock()
		defer { lock.unlock() }
		self.token = token
	}

	public func openRouterKey() throws -> String? {
		lock.lock()
		defer { lock.unlock() }
		return openRouter
	}

	public func storeOpenRouterKey(_ key: String) throws {
		lock.lock()
		defer { lock.unlock() }
		openRouter = key
		storedOpenRouterKeys += 1
	}

	public func intervalsCredential() throws -> IntervalsCredential? {
		lock.lock()
		defer { lock.unlock() }
		return intervals
	}

	public func storeIntervalsCredential(_ credential: IntervalsCredential) throws {
		lock.lock()
		defer { lock.unlock() }
		intervals = credential
	}
}
