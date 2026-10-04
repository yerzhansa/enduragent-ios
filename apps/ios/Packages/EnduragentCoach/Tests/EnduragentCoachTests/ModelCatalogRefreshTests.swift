import EnduragentCoachFixtures
import Foundation
import Synchronization
import Testing

@testable import EnduragentCoach

@Suite struct ModelCatalogRefreshTests {
	private let selected = ModelCatalog.bundled.orderedEntries[0]
	private let addedID = ModelID(rawValue: "fixture/refreshed-model")

	@Test func newerChoicesSurviveRestartWithoutChangingSelection() async throws {
		let fixture = try Fixture()
		let coach = try await fixture.coach(source: FakeModelCatalogSource(response: .newer))
		let choices = try await refreshedChoices(coach, cache: .available(.downloaded))
		#expect(choices.catalog.catalog.entries[addedID]?.displayName == "Refreshed Coach")
		#expect(choices.selected == selected)
		try await fixture.proveReply(coach, model: selected.id)
		await coach.lifecycle(.willTerminate)

		let reopened = try await fixture.coach(source: FakeModelCatalogSource(response: .offline))
		let restored = try #require(try await reopened.observedStatus().access.modelChoices)
		#expect(restored == choices)
		try await fixture.proveReply(reopened, model: selected.id)
		let outcome = await reopened.changeModelAccess(.selectOpenRouterModel(addedID))
		guard case .replaced = outcome else {
			Issue.record("A downloaded catalog choice must be selectable")
			await reopened.lifecycle(.willTerminate)
			return
		}
		#expect(try await reopened.observedStatus().access.model == addedID)
		try await fixture.proveReply(reopened, model: addedID, selectionWrites: 1)
		await reopened.lifecycle(.willTerminate)
	}

	@Test(arguments: RejectedResponse.allCases)
	func rejectedRefreshRetainsDownloadedChoices(_ response: RejectedResponse) async throws {
		let fixture = try Fixture()
		let first = try await fixture.coach(source: FakeModelCatalogSource(response: .newer))
		let lastUsable = try await refreshedChoices(first, cache: .available(.downloaded))
		await first.lifecycle(.willTerminate)

		let source: any ModelCatalogSource
		if response == .equal {
			source = CatalogDataSource(data: try lastUsable.catalog.catalog.encoded())
		} else {
			source = FakeModelCatalogSource(response: response.script)
		}
		let coach = try await fixture.coach(source: source)
		let retained = try await refreshedChoices(
			coach, cache: .retained(.downloaded, response.issue))
		#expect(retained.catalog.catalog == lastUsable.catalog.catalog)
		#expect(retained.selected == selected)
		try await fixture.proveReply(coach, model: selected.id)
		await coach.lifecycle(.willTerminate)

		let reopened = try await fixture.coach(source: FakeModelCatalogSource(response: .offline))
		let restored = try #require(try await reopened.observedStatus().access.modelChoices)
		#expect(restored.catalog.catalog == lastUsable.catalog.catalog)
		#expect(restored.catalog.cache == .available(.downloaded))
		#expect(restored.selected == selected)
		try await fixture.proveReply(reopened, model: selected.id)
		await reopened.lifecycle(.willTerminate)
	}

	@Test(arguments: [AccessMethod.openRouterAccount, .credits])
	func pendingRefreshDoesNotHoldCoachingOrChangeWhoPays(_ method: AccessMethod) async throws {
		let fixture = try Fixture(method: method)
		let gate = FakeModelGate()
		let source = FakeModelCatalogSource(response: .held, gate: gate)
		let coach = try await fixture.coach(source: source)
		let stream = await coach.observeStatus()
		try await beforeDeadline(within: .hangGuard) { await coach.lifecycle(.becameActive) }
		try await waitUntil { source.requestCount == 1 }
		try await beforeDeadline(within: .hangGuard) {
			while await gate.arrivals == 0 { await Task.yield() }
		}
		if method == .openRouterAccount {
			let status = try #require(
				try await stream.status {
					$0.access.modelChoices?.catalog.cache == .refreshing(.bundled)
				})
			#expect(status.access.model == selected.id)
		}
		try await beforeDeadline(within: .hangGuard) { await coach.lifecycle(.becameActive) }
		#expect(source.requestCount == 1)
		#expect(await gate.arrivals == 1)
		try await fixture.proveReply(coach, model: selected.id, method: method)
		#expect(await gate.arrivals == 1)
		await gate.release()
		if method == .openRouterAccount {
			_ = try #require(
				try await stream.status {
					$0.access.modelChoices?.catalog.cache == .available(.downloaded)
				})
		}
		try await fixture.proveReply(coach, model: selected.id, method: method)
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
		let choices = try await refreshedChoices(coach, cache: .retained(.bundled, .offline))
		#expect(choices.catalog.catalog == .bundled)
		#expect(choices.selected == selected)
		try await fixture.proveReply(coach, model: selected.id)
		await coach.lifecycle(.willTerminate)
		let reopened = try await fixture.coach(source: FakeModelCatalogSource(response: .offline))
		#expect(
			try await reopened.observedStatus().access.modelChoices?.catalog.catalog == .bundled)
		try await fixture.proveReply(reopened, model: selected.id)
		await reopened.lifecycle(.willTerminate)
	}

	@Test func omittedSelectionKeepsItsNameAndRequestAfterRestart() async throws {
		let fixture = try Fixture()
		let coach = try await fixture.coach(
			source: FakeModelCatalogSource(response: .omittedSelectedModel))
		let choices = try await refreshedChoices(coach, cache: .available(.downloaded))
		#expect(choices.catalog.catalog.entries[selected.id] == nil)
		#expect(choices.catalog.catalog.entries[addedID] != nil)
		#expect(choices.selected.details.displayName == "DeepSeek V4.1 Flash")
		#expect(choices.selected == selected)
		try await fixture.proveReply(coach, model: selected.id)
		await coach.lifecycle(.willTerminate)
		let reopened = try await fixture.coach(source: FakeModelCatalogSource(response: .offline))
		let restored = try #require(try await reopened.observedStatus().access.modelChoices)
		#expect(restored == choices)
		try await fixture.proveReply(reopened, model: selected.id)
		await reopened.lifecycle(.willTerminate)
	}

	@Test func firstSignInStillUsesTheBuiltInModelAfterAnOmission() async throws {
		let fixture = try Fixture()
		let coach = try await fixture.coach(
			source: FakeModelCatalogSource(response: .omittedSelectedModel))
		_ = try await refreshedChoices(coach, cache: .available(.downloaded))
		_ = await coach.changeModelAccess(.useCredits)
		let credits = try await coach.observedStatus()
		guard case .required(let challenge) = credits.access.consent else {
			Issue.record("Credits needs its own consent")
			await coach.lifecycle(.willTerminate)
			return
		}
		#expect(challenge.target.entry == selected)
		try await coach.recordConsent(challenge)
		try await fixture.proveReply(
			coach, model: selected.id, method: .credits, selectionWrites: 1)
		let outcome = await coach.changeModelAccess(.signInToOpenRouter)
		guard case .replaced(let summary, _) = outcome else {
			Issue.record("First sign-in must retain the built-in model after a catalog omission")
			await coach.lifecycle(.willTerminate)
			return
		}
		guard case .openRouterAccount(let choice) = summary.selection else {
			Issue.record("Sign-in must select the OpenRouter account")
			await coach.lifecycle(.willTerminate)
			return
		}
		#expect(choice.model == selected.id)
		let status = try await coach.observedStatus()
		#expect(status.access.modelChoices?.selected == selected)
		guard case .required(let accountConsent) = status.access.consent else {
			Issue.record("First sign-in needs OpenRouter consent")
			await coach.lifecycle(.willTerminate)
			return
		}
		try await coach.recordConsent(accountConsent)
		#expect(
			replyText(try await coach.sendAndSettle("Use the first sign-in model"))
				== selected.id.rawValue)
		#expect(fixture.transport.requests.last?.model == selected.id)
		#expect(fixture.transport.requests.last?.credential.method == .openRouterAccount)
		await coach.lifecycle(.willTerminate)
	}

	@Test func failedCacheReplacementDoesNotPublishNewChoices() async throws {
		let fixture = try Fixture()
		let first = try await fixture.coach(source: FakeModelCatalogSource(response: .newer))
		let lastUsable = try await refreshedChoices(first, cache: .available(.downloaded))
		await first.lifecycle(.willTerminate)
		let newer = try ModelCatalog(revision: 3, entries: [selected])
		let coach = try await fixture.coach(
			source: CatalogDataSource(data: try newer.encoded()),
			cache: RejectingCatalogCache(cache: FileModelCatalogCache(directory: fixture.directory))
		)
		let retained = try await refreshedChoices(
			coach, cache: .retained(.downloaded, .storageUnavailable))
		#expect(retained.catalog.catalog == lastUsable.catalog.catalog)
		try await fixture.proveReply(coach, model: selected.id)
		await coach.lifecycle(.willTerminate)
		let reopened = try await fixture.coach(source: FakeModelCatalogSource(response: .offline))
		#expect(
			try await reopened.observedStatus().access.modelChoices?.catalog.catalog
				== lastUsable.catalog.catalog)
		try await fixture.proveReply(reopened, model: selected.id)
		await reopened.lifecycle(.willTerminate)
	}

	private func refreshedChoices(_ coach: Coach, cache: CatalogCacheState) async throws
		-> OpenRouterModelChoices
	{
		let stream = await coach.observeStatus()
		await coach.lifecycle(.becameActive)
		let status = try #require(
			try await stream.status { $0.access.modelChoices?.catalog.cache == cache })
		return try #require(status.access.modelChoices)
	}

	final class Fixture: Sendable {
		let directory: URL
		let records = InMemoryRecordLog()
		let transport = FakeModelTransport { request in
			ScriptedReply([.text(request.model.rawValue), .finish(reason: .stop)])
		}
		let originalSelection: SavedAccessReference?
		private let opened = Mutex<FixtureSecretStoreBacking?>(nil)

		init(method: AccessMethod = .openRouterAccount) throws {
			directory = try TestTemporaryFolders.make()
			try FileManager.default.createDirectory(
				at: directory, withIntermediateDirectories: true)
			let secrets = try ICloudKeychainStore.fixture(directory: directory)
			try secrets.store.installOpenRouterChoice(
				model: ModelCatalog.bundled.orderedEntries[0].id, key: "synthetic-refresh-account",
				catalog: .bundled)
			try secrets.store.storeCreditsAccount(
				CreditsAccount(appAccountToken: UUID(), key: "synthetic-refresh-credits"))
			if method == .credits { try secrets.store.storeAccessSelection(.init(.credits)) }
			originalSelection = try secrets.store.accessSelection()
		}

		func coach(source: any ModelCatalogSource, cache: (any ModelCatalogCache)? = nil)
			async throws -> Coach
		{
			let reopened = try ICloudKeychainStore.fixture(directory: directory)
			opened.withLock { $0 = reopened.backing }
			let secrets = reopened.store
			let clock = FixedClock(now: "1998-06-13T08:00:00+02:00", timeZone: "Europe/Amsterdam")
			let coach = Coach(
				sport: .cycling,
				ports: CoachPorts(
					records: RecordStore(log: records), secrets: secrets,
					models: ModelService(
						catalogSource: source,
						catalogCache: cache ?? FileModelCatalogCache(directory: directory)
					) { [transport] _ in transport },
					training: .fake { _, _ in FakeIntervalsClient(athleteName: "Ada", ftp: 250) },
					credits: .fake(FakeCreditsClient()), host: ImmediateExecutionHost(),
					clock: clock,
					openRouterSignIn: .fake(
						authorizer: FakeOpenRouterAuthorizer(
							response: .completed(
								.success(OpenRouterAuthCode(code: "fixture-refresh-code")))))),
				builtInModel: ModelCatalog.bundled.orderedEntries[0].id,
				displayLocale: testDisplayLocale, coalescing: quickWindow)
			let status = try await coach.observedStatus()
			if case .required(let challenge) = status.access.consent {
				try await coach.recordConsent(challenge)
			}
			return coach
		}

		func proveReply(
			_ coach: Coach, model: ModelID, method: AccessMethod = .openRouterAccount,
			selectionWrites: Int? = nil
		) async throws {
			#expect(
				replyText(try await coach.sendAndSettle("Keep my model choice")) == model.rawValue)
			let request = try #require(transport.requests.last)
			#expect(request.model == model)
			#expect(request.credential.method == method)
			#expect(
				request.credential.secret
					== (method == .credits
						? "synthetic-refresh-credits" : "synthetic-refresh-account"))
			let selectionAccount = CredentialSlot.accessSelection.rawValue
			#expect(opened.withLock { $0?.writes(to: selectionAccount) } == (selectionWrites ?? 0))
			if selectionWrites == nil {
				#expect(
					try ICloudKeychainStore.fixture(directory: directory).store.accessSelection()
						== originalSelection)
			}
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
}
