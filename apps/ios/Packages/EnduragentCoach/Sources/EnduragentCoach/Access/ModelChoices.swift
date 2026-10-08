import Foundation

public struct NamedProvider: Hashable, Sendable {
	public let name: String
	package let routingSlug: String

	package init(name: String, routingSlug: String) throws {
		guard ModelDetails.validName(name),
			routingSlug.range(of: #"\A[a-z0-9]+(?:[/-][a-z0-9]+)*\z"#, options: .regularExpression)
				!= nil,
			routingSlug.count <= 128
		else { throw ModelCatalogIssue.malformed }
		self.name = name
		self.routingSlug = routingSlug
	}
}

public struct ModelDetails: Hashable, Sendable {
	public let displayName: String
	public let provider: NamedProvider

	package init(displayName: String, provider: NamedProvider) throws {
		guard Self.validName(displayName) else { throw ModelCatalogIssue.malformed }
		self.displayName = displayName
		self.provider = provider
	}

	package static func validName(_ name: String) -> Bool {
		!name.isEmpty && name.count <= 200
			&& name == name.trimmingCharacters(in: .whitespacesAndNewlines)
			&& name.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
	}
}

public struct ModelCatalogEntry: Hashable, Sendable {
	public let id: ModelID
	public let details: ModelDetails

	package init(id: ModelID, details: ModelDetails) throws {
		guard id.rawValue.count <= 200,
			id.rawValue.range(
				of: #"\A[a-z0-9][a-z0-9._-]*/[a-z0-9][a-z0-9._-]*(?::[a-z0-9._-]+)?\z"#,
				options: .regularExpression) != nil
		else { throw ModelCatalogIssue.malformed }
		self.id = id
		self.details = details
	}
}

public struct OpenRouterModelChoices: Equatable, Sendable {
	public let selected: ModelCatalogEntry
	public let catalog: ModelCatalogStatus
}

public struct ModelCatalogStatus: Equatable, Sendable {
	public let catalog: ModelCatalog
	public let cache: CatalogCacheState
}

public enum CatalogOrigin: Equatable, Sendable {
	case bundled
	case downloaded
}

public enum CatalogCacheState: Equatable, Sendable {
	case available(CatalogOrigin)
	case refreshing(CatalogOrigin)
	case retained(CatalogOrigin, CatalogIssue)
}

public enum CatalogIssue: Error, Equatable, Sendable {
	case offline
	case malformed
	case stale
	case noUsableChoices
	case storageUnavailable
}
