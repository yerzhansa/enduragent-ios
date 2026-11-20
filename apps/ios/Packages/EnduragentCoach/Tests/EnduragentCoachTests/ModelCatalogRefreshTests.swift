import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

@Suite struct ModelCatalogRefreshTests {
	private let selected = ModelCatalog.bundled.orderedEntries[0]
	private let addedID = ModelID(rawValue: "fixture/refreshed-model")

	@Test func newerCatalogSurvivesRestartWithoutChangingTheBuiltInModel() async throws {
		let fixture = try Fixture()
		let coach = try await fixture.coach(source: FakeModelCatalogSource(response: .newer))
		let refreshed = try await refreshedCatalog(coach, cache: .available(.downloaded))
		#expect(refreshed.catalog.entries[addedID]?.displayName == "Refreshed Coach")
		try await fixture.proveReply(coach, model: selected.id)
		await coach.lifecycle(.willTerminate)

		let reopened = try await fixture.coach(source: FakeModelCatalogSource(response: .offline))
		#expect(await reopened.catalogs.snapshot() == refreshed)
		try await fixture.proveReply(reopened, model: selected.id)
		await reopened.lifecycle(.willTerminate)
	}

	@Test(arguments: RejectedResponse.allCases)
	func rejectedRefreshRetainsDownloadedChoices(_ response: RejectedResponse) async throws {
		let fixture = try Fixture()
		let first = try await fixture.coach(source: FakeModelCatalogSource(response: .newer))
		let lastUsable = try await refreshedCatalog(first, cache: .available(.downloaded))
		await first.lifecycle(.willTerminate)

		let source: any ModelCatalogSource
		if response == .equal {
			source = CatalogDataSource(data: try lastUsable.catalog.encoded())
		} else {
			source = FakeModelCatalogSource(response: response.script)
		}
		let coach = try await fixture.coach(source: source)
		let retained = try await refreshedCatalog(
			coach, cache: .retained(.downloaded, response.issue))
		#expect(retained.catalog == lastUsable.catalog)
		try await fixture.proveReply(coach, model: selected.id)
		await coach.lifecycle(.willTerminate)

		let reopened = try await fixture.coach(source: FakeModelCatalogSource(response: .offline))
		let restored = await reopened.catalogs.snapshot()
		#expect(restored.catalog == lastUsable.catalog)
		#expect(restored.cache == .available(.downloaded))
		try await fixture.proveReply(reopened, model: selected.id)
		await reopened.lifecycle(.willTerminate)
	}

	@Test func pendingRefreshDoesNotHoldCoaching() async throws {
		let fixture = try Fixture()
		let gate = FakeModelGate()
		let source = FakeModelCatalogSource(response: .held, gate: gate)
		let coach = try await fixture.coach(source: source)
		try await beforeDeadline(within: .hangGuard) { await coach.lifecycle(.becameActive) }
		try await waitUntil { source.requestCount == 1 }
		try await beforeDeadline(within: .hangGuard) {
			while await gate.arrivals == 0 { await Task.yield() }
		}
		#expect(await coach.catalogs.snapshot().cache == .refreshing(.bundled))
		try await beforeDeadline(within: .hangGuard) { await coach.lifecycle(.becameActive) }
		#expect(source.requestCount == 1)
		#expect(await gate.arrivals == 1)
		try await fixture.proveReply(coach, model: selected.id)
		#expect(await gate.arrivals == 1)
		await gate.release()
		try await beforeDeadline(within: .hangGuard) {
			while await coach.catalogs.snapshot().cache != .available(.downloaded) {
				await Task.yield()
			}
		}
		try await fixture.proveReply(coach, model: selected.id)
		await coach.lifecycle(.willTerminate)
	}

	@Test(arguments: UnusableCache.allCases)
	func unusableCacheFallsBackToBundle(_ seed: UnusableCache) async throws {
		let fixture = try Fixture()
		if let data = seed.data {
			try data.write(
				to: fixture.directory.appending(path: "model-catalog.json"), options: .atomic)
		}
		let coach = try await fixture.coach(source: FakeModelCatalogSource(response: .offline))
		let refreshed = try await refreshedCatalog(coach, cache: .retained(.bundled, .offline))
		#expect(refreshed.catalog == .bundled)
		try await fixture.proveReply(coach, model: selected.id)
		await coach.lifecycle(.willTerminate)
		let reopened = try await fixture.coach(source: FakeModelCatalogSource(response: .offline))
		#expect(await reopened.catalogs.snapshot().catalog == .bundled)
		try await fixture.proveReply(reopened, model: selected.id)
		await reopened.lifecycle(.willTerminate)
	}

	@Test func omittedBuiltInModelKeepsItsRequestAfterRestart() async throws {
		let fixture = try Fixture()
		let coach = try await fixture.coach(
			source: FakeModelCatalogSource(response: .omittedSelectedModel))
		let refreshed = try await refreshedCatalog(coach, cache: .available(.downloaded))
		#expect(refreshed.catalog.entries[selected.id] == nil)
		#expect(refreshed.catalog.entries[addedID] != nil)
		try await fixture.proveReply(coach, model: selected.id)
		await coach.lifecycle(.willTerminate)
		let reopened = try await fixture.coach(source: FakeModelCatalogSource(response: .offline))
		#expect(await reopened.catalogs.snapshot() == refreshed)
		try await fixture.proveReply(reopened, model: selected.id)
		await reopened.lifecycle(.willTerminate)
	}

	@Test(arguments: DownloadedBuiltIn.allCases)
	func creditsUseTheCurrentBuiltInEntry(_ downloaded: DownloadedBuiltIn) async throws {
		let fixture = try Fixture()
		let expected = try downloaded.entry(for: selected)
		let coach = try await fixture.coach(source: try downloaded.source(for: selected))
		_ = try await refreshedCatalog(coach, cache: .available(.downloaded))
		let credits = try await coach.observedStatus()
		if case .required(let challenge) = credits.access.consent {
			#expect(challenge.target.entry == expected)
			try await coach.recordConsent(challenge)
		}
		try await fixture.proveReply(coach, model: selected.id)
		#expect(fixture.transport.requests.last?.provider == expected.details.provider)
		await coach.lifecycle(.willTerminate)
	}

	@Test func failedCacheReplacementDoesNotPublishNewChoices() async throws {
		let fixture = try Fixture()
		let first = try await fixture.coach(source: FakeModelCatalogSource(response: .newer))
		let lastUsable = try await refreshedCatalog(first, cache: .available(.downloaded))
		await first.lifecycle(.willTerminate)
		let newer = try ModelCatalog(
			revision: ModelCatalog.bundled.revision + 2, entries: [selected])
		let coach = try await fixture.coach(
			source: CatalogDataSource(data: try newer.encoded()),
			cache: RejectingCatalogCache(cache: FileModelCatalogCache(directory: fixture.directory))
		)
		let retained = try await refreshedCatalog(
			coach, cache: .retained(.downloaded, .storageUnavailable))
		#expect(retained.catalog == lastUsable.catalog)
		try await fixture.proveReply(coach, model: selected.id)
		await coach.lifecycle(.willTerminate)
		let reopened = try await fixture.coach(source: FakeModelCatalogSource(response: .offline))
		#expect(await reopened.catalogs.snapshot().catalog == lastUsable.catalog)
		try await fixture.proveReply(reopened, model: selected.id)
		await reopened.lifecycle(.willTerminate)
	}

	private func refreshedCatalog(_ coach: Coach, cache: CatalogCacheState) async throws
		-> ModelCatalogStatus
	{
		await coach.lifecycle(.becameActive)
		try await beforeDeadline(within: .hangGuard) {
			while await coach.catalogs.snapshot().cache != cache { await Task.yield() }
		}
		return await coach.catalogs.snapshot()
	}

	final class Fixture: Sendable {
		let directory: URL
		let records = InMemoryRecordLog()
		let transport = FakeModelTransport { request in
			ScriptedReply([.text(request.model.rawValue), .finish(reason: .stop)])
		}

		init() throws {
			directory = try TestTemporaryFolders.make()
			try FileManager.default.createDirectory(
				at: directory, withIntermediateDirectories: true)
			let secrets = try ICloudKeychainStore.fixture(directory: directory)
			try secrets.store.storeCreditsAccount(
				CreditsAccount(appAccountToken: UUID(), key: "synthetic-refresh-credits"))
		}

		func coach(source: any ModelCatalogSource, cache: (any ModelCatalogCache)? = nil)
			async throws -> Coach
		{
			let secrets = try ICloudKeychainStore.fixture(directory: directory).store
			let coach = makeCoach(
				records: RecordStore(log: records), secrets: secrets,
				models: ModelService(
					catalogSource: source,
					catalogCache: cache ?? FileModelCatalogCache(directory: directory)
				) { [transport] _ in transport },
				builtInModel: ModelCatalog.bundled.orderedEntries[0].id)
			let status = try await coach.observedStatus()
			if case .required(let challenge) = status.access.consent {
				try await coach.recordConsent(challenge)
			}
			return coach
		}

		func proveReply(_ coach: Coach, model: ModelID) async throws {
			#expect(
				replyText(try await coach.sendAndSettle("Keep my model choice")) == model.rawValue)
			let request = try #require(transport.requests.last)
			#expect(request.model == model)
			#expect(
				request.credential
					== ProviderCredential(secret: "synthetic-refresh-credits", method: .credits))
		}
	}

	enum RejectedResponse: CaseIterable {
		case malformed, older, equal, offline, empty
		var script: FixtureCatalogResponse {
			switch self {
			case .malformed: .malformed
			case .older, .equal: .stale
			case .offline: .offline
			case .empty: .empty
			}
		}
		var issue: CatalogIssue {
			switch self {
			case .malformed: .malformed
			case .older, .equal: .stale
			case .offline: .offline
			case .empty: .noUsableChoices
			}
		}
	}

	enum DownloadedBuiltIn: CaseIterable {
		case omitted, movedHost

		func entry(for listed: ModelCatalogEntry) throws -> ModelCatalogEntry {
			switch self {
			case .omitted: listed
			case .movedHost:
				try ModelCatalogEntry(
					id: listed.id,
					details: ModelDetails(
						displayName: listed.details.displayName, provider: .fixtureHost))
			}
		}

		func source(for listed: ModelCatalogEntry) throws -> any ModelCatalogSource {
			switch self {
			case .omitted: FakeModelCatalogSource(response: .omittedSelectedModel)
			case .movedHost:
				CatalogDataSource(
					data: try ModelCatalog(
						revision: ModelCatalog.bundled.revision + 1,
						entries: ModelCatalog.bundled.orderedEntries.map {
							$0.id == listed.id ? try entry(for: listed) : $0
						}
					).encoded())
			}
		}
	}

	enum UnusableCache: CaseIterable {
		case absent, malformed, empty, stale
		var data: Data? {
			switch self {
			case .absent: nil
			case .malformed: Data("broken cache".utf8)
			case .empty: Data(#"{"revision":3,"entries":[]}"#.utf8)
			case .stale:
				Data(
					#"{"revision":1,"entries":[{"id":"fixture/stale-model","displayName":"Stale","provider":{"name":"Host","routingSlug":"host"}}]}"#
						.utf8)
			}
		}
	}
}

private struct CatalogDataSource: ModelCatalogSource {
	let data: Data
	func download() async throws -> Data { data }
}

private struct RejectingCatalogCache: ModelCatalogCache {
	let cache: FileModelCatalogCache
	func load() throws -> ModelCatalog? { try cache.load() }
	func replaceAtomically(_ catalog: ModelCatalog) throws {
		throw CocoaError(.fileWriteNoPermission)
	}
	func erase() throws { try cache.erase() }
}
