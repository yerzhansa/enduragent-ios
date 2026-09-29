import Foundation
import Security

public final class FakeSecretStore: SecretStore, @unchecked Sendable {
	private struct Contents: Codable {
		private enum CodingKeys: String, CodingKey {
			case creditsAccount, openRouterKey, openRouterAccountKey, intervals, accessSelection
			case intervalsApiKey, intervalsOAuthAccess, intervalsOAuthRefresh
		}

		private enum LegacyKeys: String, CodingKey {
			case appAccountToken, stagedIntervals
		}

		var creditsAccount: CreditsAccount?
		var openRouterKey: String?
		var openRouterAccountKey: String?
		var intervals: StoredIntervalsConnection?
		var accessSelection: StoredAccessSelection?
		var intervalsApiKey: String?
		var intervalsOAuthAccess: String?
		var intervalsOAuthRefresh: String?
		var needsCreditsRewrite = false

		init(creditsAccount: CreditsAccount? = nil) {
			self.creditsAccount = creditsAccount
		}

		init(from decoder: any Decoder) throws {
			let container = try decoder.container(keyedBy: CodingKeys.self)
			let legacy = try decoder.container(keyedBy: LegacyKeys.self)
			creditsAccount = try restoredCreditsAccount(
				current: container.decodeIfPresent(CreditsAccount.self, forKey: .creditsAccount),
				undo: Self.legacyUndo(legacy),
				legacyKey: container.decodeIfPresent(String.self, forKey: .openRouterKey),
				legacyToken: legacy.decodeIfPresent(UUID.self, forKey: .appAccountToken))
			if creditsAccount == nil {
				openRouterKey = try container.decodeIfPresent(String.self, forKey: .openRouterKey)
			}
			needsCreditsRewrite =
				creditsAccount != nil
				&& (legacy.contains(.appAccountToken) || legacy.contains(.stagedIntervals)
					|| container.contains(.openRouterKey))
			openRouterAccountKey = try container.decodeIfPresent(
				String.self, forKey: .openRouterAccountKey)
			intervals = try container.decodeIfPresent(
				StoredIntervalsConnection.self, forKey: .intervals)
			accessSelection = try container.decodeIfPresent(
				StoredAccessSelection.self, forKey: .accessSelection)
			intervalsApiKey = try container.decodeIfPresent(String.self, forKey: .intervalsApiKey)
			intervalsOAuthAccess = try container.decodeIfPresent(
				String.self, forKey: .intervalsOAuthAccess)
			intervalsOAuthRefresh = try container.decodeIfPresent(
				String.self, forKey: .intervalsOAuthRefresh)
		}

		private static func legacyUndo(_ container: KeyedDecodingContainer<LegacyKeys>) throws
			-> LegacyCreditsUndo?
		{
			do {
				return try container.decodeIfPresent(
					LegacyCreditsUndo.self, forKey: .stagedIntervals)
			} catch is DecodingError {
				return nil
			}
		}

		mutating func replaceCredits(with account: CreditsAccount) {
			creditsAccount = account
			openRouterKey = nil
		}

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
			case .creditsAccount: creditsAccount != nil
			case .openRouterAccountKey: openRouterAccountKey != nil
			case .intervalsConnection: intervalsItem != nil
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
	public private(set) var storedCreditsAccounts = 0

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
		self.contents = Contents(
			creditsAccount: appAccountToken.map { CreditsAccount(appAccountToken: $0, key: nil) })
	}

	public init(directory: URL) throws {
		let file = directory.appending(path: Self.fileName)
		self.file = file
		if FileManager.default.fileExists(atPath: file.path) {
			self.contents = try JSONDecoder().decode(Contents.self, from: Data(contentsOf: file))
			if contents.needsCreditsRewrite { try persist(contents) }
		} else {
			self.contents = Contents()
		}
	}

	public func creditsAccount() throws -> CreditsAccount? {
		try read(.creditsAccount) { $0.creditsAccount }
	}

	public func prepareCreditsAccount() throws -> CreditsAccount {
		if let account = try creditsAccount() { return account }
		return try write { contents in
			if let account = contents.creditsAccount { return account }
			let account = CreditsAccount(appAccountToken: UUID(), key: contents.openRouterKey)
			contents.replaceCredits(with: account)
			storedCreditsAccounts += 1
			return account
		}
	}

	public func storeCreditsAccount(_ account: CreditsAccount) throws {
		try write {
			$0.replaceCredits(with: account)
			storedCreditsAccounts += 1
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
			case .creditsAccount:
				contents.creditsAccount = nil
			case .openRouterAccountKey:
				contents.openRouterAccountKey = nil
			case .intervalsConnection:
				contents.replaceIntervals(with: nil)
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

	private func write<Value>(_ body: (inout Contents) -> Value) throws -> Value {
		try withLock {
			try checkUnlocked()
			if failsNextWrite {
				failsNextWrite = false
				throw KeychainStoreError(status: errSecNotAvailable)
			}
			var replacement = contents
			let value = body(&replacement)
			try persist(replacement)
			contents = replacement
			return value
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
