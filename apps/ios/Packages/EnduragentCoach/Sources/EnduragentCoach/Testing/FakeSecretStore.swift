import Foundation
import Security

public final class FakeSecretStore: SecretStore, @unchecked Sendable {
	private struct Contents: Codable {
		var appAccountToken: UUID
		var openRouterKey: String?
		var openRouterAccountKey: String?
		var intervals: StoredIntervalsConnection?
		var stagedIntervals: StoredCredentialReplacement?
		var accessSelection: StoredAccessSelection?
		var intervalsApiKey: String?
		var intervalsOAuthAccess: String?
		var intervalsOAuthRefresh: String?

		var intervalsItem: StoredIntervalsConnection? {
			if let intervals {
				return intervals
			}
			let legacy: IntervalsCredential
			if let intervalsApiKey {
				legacy = .apiKey(intervalsApiKey)
			} else if let intervalsOAuthAccess, let intervalsOAuthRefresh {
				legacy = .oauth(access: intervalsOAuthAccess, refresh: intervalsOAuthRefresh)
			} else {
				return nil
			}
			return StoredIntervalsConnection(
				IntervalsConnection(
					id: nil, credential: legacy, selection: .keyOwner, resolvedAthlete: nil))
		}

		func holds(_ slot: CredentialSlot) -> Bool {
			switch slot {
			case .appAccountToken: true
			case .creditsKey: openRouterKey != nil
			case .openRouterAccountKey: openRouterAccountKey != nil
			case .intervalsConnection: intervalsItem != nil
			case .intervalsConnectionStaging: stagedIntervals != nil
			case .accessSelection: accessSelection != nil
			}
		}

		mutating func replaceIntervals(with item: StoredIntervalsConnection?) {
			intervals = item
			intervalsApiKey = nil
			intervalsOAuthAccess = nil
			intervalsOAuthRefresh = nil
		}
	}

	public static let fileName = "secrets.json"

	private let lock = NSLock()
	private let file: URL?
	private var contents: Contents
	private var isLocked = false
	private var failsNextWrite = false
	private var slotsRead: [CredentialSlot] = []
	public private(set) var storedOpenRouterKeys = 0

	public var locked: Bool {
		get { withLock { isLocked } }
		set { withLock { isLocked = newValue } }
	}

	public var failNextWrite: Bool {
		get { withLock { failsNextWrite } }
		set { withLock { failsNextWrite = newValue } }
	}

	public var reads: [CredentialSlot] {
		withLock { slotsRead }
	}

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
			try persist(contents)
		}
	}

	public func appAccountToken() throws -> UUID {
		try read(.appAccountToken) {
			if case .credits(_, let token)? = $0.stagedIntervals { return token }
			return $0.appAccountToken
		}
	}

	public func storeAppAccountToken(_ token: UUID) throws {
		try write { $0.appAccountToken = token }
	}

	public func openRouterKey() throws -> String? {
		try read(.creditsKey) {
			if case .credits(let key, _)? = $0.stagedIntervals { return key }
			return $0.openRouterKey
		}
	}

	public func storeOpenRouterKey(_ key: String) throws {
		try write {
			$0.openRouterKey = key
			storedOpenRouterKeys += 1
		}
	}

	public func openRouterAccountKey() throws -> String? {
		try read(.openRouterAccountKey) { $0.openRouterAccountKey }
	}

	public func storeOpenRouterAccountKey(_ key: String) throws {
		try write { $0.openRouterAccountKey = key }
	}

	public func intervalsConnection() throws -> IntervalsConnection? {
		try read(.intervalsConnection) { $0.intervalsItem }?.connection()
	}

	public func storeIntervalsConnection(_ connection: IntervalsConnection) throws {
		try write { $0.replaceIntervals(with: StoredIntervalsConnection(connection)) }
	}

	public func stagedReplacement() throws -> CredentialReplacement? {
		try read(.intervalsConnectionStaging) {
			$0.stagedIntervals
		}?.replacement()
	}

	public func stageReplacement(_ replacement: CredentialReplacement) throws {
		try write {
			$0.stagedIntervals = StoredCredentialReplacement(replacement)
		}
	}

	public func rollbackStagedReplacement() throws {
		guard
			try withLock({
				try checkUnlocked()
				return contents.holds(.intervalsConnectionStaging)
			})
		else { return }
		try write {
			if case .credits(let key, let token)? = $0.stagedIntervals {
				$0.openRouterKey = key
				$0.appAccountToken = token
			}
			$0.stagedIntervals = nil
		}
	}

	public func accessSelection() throws -> AccessSelection? {
		try read(.accessSelection) { $0.accessSelection }?.selection()
	}

	public func storeAccessSelection(_ selection: AccessSelection) throws {
		try write { $0.accessSelection = StoredAccessSelection(selection) }
	}

	public func delete(_ slot: CredentialSlot) throws {
		let held = try withLock {
			try checkUnlocked()
			return contents.holds(slot)
		}
		guard held else { return }
		try write { contents in
			switch slot {
			case .appAccountToken:
				contents.appAccountToken = UUID()
			case .creditsKey:
				contents.openRouterKey = nil
			case .openRouterAccountKey:
				contents.openRouterAccountKey = nil
			case .intervalsConnection:
				contents.replaceIntervals(with: nil)
			case .intervalsConnectionStaging:
				contents.stagedIntervals = nil
			case .accessSelection:
				contents.accessSelection = nil
			}
		}
	}

	private func read<Value>(_ slot: CredentialSlot, _ body: (Contents) -> Value) throws -> Value {
		try withLock {
			slotsRead.append(slot)
			try checkUnlocked()
			return body(contents)
		}
	}

	private func write(_ body: (inout Contents) -> Void) throws {
		try withLock {
			try checkUnlocked()
			if failsNextWrite {
				failsNextWrite = false
				throw KeychainStoreError(status: errSecNotAvailable)
			}
			var replacement = contents
			body(&replacement)
			try persist(replacement)
			contents = replacement
		}
	}

	private func withLock<Value>(_ body: () throws -> Value) rethrows -> Value {
		lock.lock()
		defer { lock.unlock() }
		return try body()
	}

	private func checkUnlocked() throws {
		if isLocked {
			throw KeychainStoreError(status: errSecInteractionNotAllowed)
		}
	}

	private func persist(_ contents: Contents) throws {
		guard let file else { return }
		try JSONEncoder().encode(contents).write(to: file, options: .atomic)
	}
}
