import Foundation

public struct ConsentTarget: Hashable, Sendable {
	public let method: AccessMethod
	public let entry: ModelCatalogEntry

	package init(method: AccessMethod, entry: ModelCatalogEntry) {
		self.method = method
		self.entry = entry
	}
}

public struct ConsentChallenge: Equatable, Sendable {
	public let target: ConsentTarget
	package let generation: UUID

	package init(target: ConsentTarget, generation: UUID) {
		self.target = target
		self.generation = generation
	}
}

public struct ProviderConsent: Hashable, Sendable {
	public static let currentVersion = 2
	public let version: Int
	public let at: Date
	public let target: ConsentTarget?

	package init(target: ConsentTarget, at: Date, version: Int = Self.currentVersion) {
		self.version = version
		self.at = at
		self.target = target
	}

	package init(legacyAt at: Date, version: Int = 1) {
		self.version = version
		self.at = at
		self.target = nil
	}

	package func authorizes(_ target: ConsentTarget) -> Bool {
		version == Self.currentVersion && self.target?.method == target.method
			&& self.target?.entry.details.provider == target.entry.details.provider
	}
}

public enum AccessConsent: Equatable, Sendable {
	case required(ConsentChallenge)
	case accepted(ProviderConsent)
	case unavailable
}

public enum ConsentWriteFailure: Error, Equatable, Sendable {
	case notSaved
	case staleChallenge
}
