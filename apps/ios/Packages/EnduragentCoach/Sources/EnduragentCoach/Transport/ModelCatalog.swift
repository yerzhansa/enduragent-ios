import Foundation

public struct ModelCatalog: Equatable, Sendable {
	public let revision: UInt64
	public let entries: [ModelID: ModelDetails]
	public let orderedEntries: [ModelCatalogEntry]

	public static let bundled: ModelCatalog = {
		guard let url = Bundle.module.url(forResource: "BundledModels", withExtension: "json")
		else {
			fatalError("Bundled model catalog is missing")
		}
		do {
			return try ModelCatalog(validating: Data(contentsOf: url))
		} catch {
			fatalError("Bundled model catalog is invalid: \(error)")
		}
	}()

	package init(revision: UInt64, entries: [ModelCatalogEntry]) throws {
		guard revision > 0 else { throw ModelCatalogIssue.malformed }
		guard !entries.isEmpty else { throw ModelCatalogIssue.noUsableChoices }
		guard Set(entries.map(\.id)).count == entries.count else {
			throw ModelCatalogIssue.malformed
		}
		self.revision = revision
		self.entries = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0.details) })
		self.orderedEntries = entries
	}

	package init(validating data: Data) throws {
		let document: ModelCatalogDocument
		do {
			document = try JSONDecoder().decode(ModelCatalogDocument.self, from: data)
		} catch {
			throw ModelCatalogIssue.malformed
		}
		try self.init(
			revision: document.revision,
			entries: document.entries.map { row in
				try ModelCatalogEntry(
					id: ModelID(rawValue: row.id),
					details: ModelDetails(
						displayName: row.displayName,
						provider: NamedProvider(
							name: row.provider.name, routingSlug: row.provider.routingSlug)))
			})
	}

	package func encoded() throws -> Data {
		try JSONEncoder().encode(
			ModelCatalogDocument(
				revision: revision,
				entries: orderedEntries.map { entry in
					ModelCatalogDocument.Entry(
						id: entry.id.rawValue, displayName: entry.details.displayName,
						provider: ModelCatalogDocument.Provider(
							name: entry.details.provider.name,
							routingSlug: entry.details.provider.routingSlug))
				}))
	}

	package func choice(_ id: ModelID, retaining details: ModelDetails? = nil) throws
		-> ModelCatalogEntry
	{
		guard let details = details ?? entries[id] else {
			throw ModelCatalogIssue.modelNotInCatalog
		}
		return try ModelCatalogEntry(id: id, details: details)
	}
}

package enum ModelCatalogIssue: Error {
	case malformed
	case noUsableChoices
	case modelNotInCatalog
}

private struct ModelCatalogDocument: Codable {
	let revision: UInt64
	let entries: [Entry]

	struct Entry: Codable {
		let id: String
		let displayName: String
		let provider: Provider
	}

	struct Provider: Codable {
		let name: String
		let routingSlug: String
	}
}
