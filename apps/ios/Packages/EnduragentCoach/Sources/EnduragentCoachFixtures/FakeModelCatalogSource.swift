import EnduragentCoach
import Foundation

public enum FixtureCatalogResponse: String, Sendable {
	case newer
	case omittedSelectedModel = "omitted-selected-model"
	case malformed
	case stale
	case offline
	case empty
	case held
}

public final class FakeModelCatalogSource: ModelCatalogSource, @unchecked Sendable {
	private let response: FixtureCatalogResponse
	private let gate: FakeModelGate
	private let lock = NSLock()
	private var downloads = 0

	public init(response: FixtureCatalogResponse, gate: FakeModelGate = FakeModelGate()) {
		self.response = response
		self.gate = gate
	}

	public var requestCount: Int { lock.withLock { downloads } }

	package func download() async throws -> Data {
		lock.withLock { downloads += 1 }
		switch response {
		case .offline: throw CatalogIssue.offline
		case .malformed: return Data("invalid catalog".utf8)
		case .empty: return Data(#"{"revision":3,"entries":[]}"#.utf8)
		case .stale: return try ModelCatalog.bundled.encoded()
		case .held:
			try await gate.enter()
			return try Self.newerCatalog(omittingSelected: false).encoded()
		case .newer, .omittedSelectedModel:
			return try Self.newerCatalog(omittingSelected: response == .omittedSelectedModel)
				.encoded()
		}
	}

	private static func newerCatalog(omittingSelected: Bool) throws -> ModelCatalog {
		guard let first = ModelCatalog.bundled.orderedEntries.first else {
			throw CatalogIssue.noUsableChoices
		}
		let added = try ModelCatalogEntry(
			id: ModelID(rawValue: "fixture/refreshed-model"),
			details: ModelDetails(displayName: "Refreshed Coach", provider: first.details.provider))
		let entries = ModelCatalog.bundled.orderedEntries.filter {
			!omittingSelected || $0.id != first.id
		}
		return try ModelCatalog(
			revision: ModelCatalog.bundled.revision + 1, entries: entries + [added])
	}
}
