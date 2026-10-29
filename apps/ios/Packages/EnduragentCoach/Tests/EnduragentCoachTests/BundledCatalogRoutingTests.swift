import Foundation
import Testing

@testable import EnduragentCoach

@Suite struct BundledCatalogRoutingTests {
	@Test func everyEntryHasAServingEndpointAndTheBuiltInHostKeepsNoData() throws {
		let snapshot = try OpenRouterRoutingSnapshot.checkedIn()
		let problems = snapshot.problems(in: .bundled, builtIn: try projectBuiltInModel())
		#expect(problems == [])
	}

	@Test(arguments: [
		("deepseek", "serves no endpoint"),
		("alibaba", "is not on the zero-data-retention list"),
	])
	func checkRefusesAHostThatCannotCarryTheBuiltInModel(slug: String, problem: String) throws {
		let snapshot = try OpenRouterRoutingSnapshot.checkedIn()
		let builtIn = try projectBuiltInModel()
		let listed = try #require(ModelCatalog.bundled.entries[builtIn])
		let pinned = try ModelCatalog(
			revision: 1,
			entries: [
				ModelCatalogEntry(
					id: builtIn,
					details: ModelDetails(
						displayName: listed.displayName,
						provider: NamedProvider(name: "Pinned Host", routingSlug: slug)))
			])
		#expect(
			snapshot.problems(in: pinned, builtIn: builtIn)
				== ["\(builtIn.rawValue) via \(slug) \(problem)"])
	}
}

struct OpenRouterRoutingSnapshot {
	struct Endpoint: Decodable, Hashable {
		let name: String
		let tag: String
	}

	private struct Endpoints: Decodable {
		struct Model: Decodable {
			struct Data: Decodable {
				let endpoints: [Endpoint]
			}
			let data: Data
		}
		let models: [String: Model]
	}

	private struct ZeroRetention: Decodable {
		let data: [Endpoint]
	}

	let endpoints: [ModelID: [Endpoint]]
	let zeroRetention: Set<Endpoint>

	static func checkedIn() throws -> OpenRouterRoutingSnapshot {
		let decoder = JSONDecoder()
		let endpoints = try decoder.decode(
			Endpoints.self,
			from: Data(try fixture("openrouter-model-endpoints", ext: "json").utf8))
		let zeroRetention = try decoder.decode(
			ZeroRetention.self,
			from: Data(try fixture("openrouter-zdr-endpoints", ext: "json").utf8))
		return OpenRouterRoutingSnapshot(
			endpoints: Dictionary(
				uniqueKeysWithValues: endpoints.models.map {
					(ModelID(rawValue: $0.key), $0.value.data.endpoints)
				}),
			zeroRetention: Set(zeroRetention.data))
	}

	func problems(in catalog: ModelCatalog, builtIn: ModelID) -> [String] {
		let unlisted = catalog.entries[builtIn] == nil ? ["\(builtIn.rawValue) is not listed"] : []
		return unlisted
			+ catalog.orderedEntries.compactMap { entry in
				let slug = entry.details.provider.routingSlug
				let served = (endpoints[entry.id] ?? []).filter {
					$0.tag == slug || $0.tag.hasPrefix(slug + "/")
				}
				let route = "\(entry.id.rawValue) via \(slug)"
				if served.isEmpty { return "\(route) serves no endpoint" }
				if entry.id == builtIn, !served.allSatisfy(zeroRetention.contains) {
					return "\(route) is not on the zero-data-retention list"
				}
				return nil
			}
	}
}
