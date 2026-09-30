import Foundation
import Security

@testable import EnduragentCoach

final class InterruptedSecretStoreBacking: SecretStoreBacking, @unchecked Sendable {
	private let base: FixtureSecretStoreBacking
	private let lock = NSLock()
	private var remainingWrites: Int?

	init(base: FixtureSecretStoreBacking) {
		self.base = base
	}

	func stop(after writes: Int) {
		lock.withLock { remainingWrites = writes }
	}

	func resume() {
		lock.withLock { remainingWrites = nil }
	}

	func copy(account: String) throws -> Data? { try base.copy(account: account) }

	func add(account: String, data: Data) throws {
		try write { try base.add(account: account, data: data) }
	}

	func update(account: String, data: Data) throws {
		try write { try base.update(account: account, data: data) }
	}

	func delete(account: String) throws {
		try write { try base.delete(account: account) }
	}

	private func write(_ body: () throws -> Void) throws {
		try lock.withLock {
			if let remainingWrites, remainingWrites == 0 {
				throw KeychainStoreError.keychain(errSecNotAvailable)
			}
			try body()
			if let remainingWrites { self.remainingWrites = remainingWrites - 1 }
		}
	}
}
