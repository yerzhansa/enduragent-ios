import EnduragentCoachFixtures
import Foundation
import Security
import Synchronization
import Testing

@testable import EnduragentCoach

@Suite struct ModelChoiceTests {
	private let catalog = ModelCatalog.bundled
	private let clock = FixedClock(now: "1998-06-13T08:00:00+02:00", timeZone: "Europe/Amsterdam")
	private let creditsKey = "synthetic-model-choice-credits"

	@Test func bundledCatalogLeadsWithTheBuiltInModelThatCreditsUse() async throws {
		let first = try #require(catalog.orderedEntries.first)
		let builtIn = try projectBuiltInModel()
		#expect(first.id == builtIn)
		let fixture = try secrets()
		let transport = FakeModelTransport(respond: reply)
		let coach = await coach(fixture.store, transport: transport, builtIn: builtIn)
		#expect(
			replyText(try await coach.sendAndSettle("Which model answers for Credits?"))
				== builtIn.rawValue)
		let request = try #require(transport.requests.last)
		#expect(request.model == first.id)
		#expect(request.provider == first.details.provider)
		#expect(request.credential == ProviderCredential(secret: creditsKey, method: .credits))
		await coach.lifecycle(.willTerminate)
	}

	@Test func replyCompactionAndExtractionUseTheBuiltInModel() async throws {
		let fixture = try secrets()
		try fixture.store.storeIntervalsConnection(testConnection)
		let transport = FakeModelTransport()
		let records = InMemoryRecordLog()
		try await seedHistory(records, clock: clock, turns: 3, tokens: 300)
		transport.respond = ScriptedReply.sequence(
			[
				.fail(
					.http(
						status: 400,
						body: #"{"error":{"message":"maximum context length exceeded"}}"#)),
				.text("Your training is checked."), .finish(reason: .stop),
			], for: .chat,
			otherwise: { _ in ScriptedReply([.text("Earlier training."), .finish(reason: .stop)]) })
		let isolatedCatalog = try ModelCatalog(
			revision: 2, entries: [try #require(catalog.orderedEntries.last)])
		let coach = await coach(
			fixture.store, transport: transport, records: records, catalog: isolatedCatalog)
		#expect(
			replyText(try await coach.sendAndSettle("Check my training"))
				== "Your training is checked.")
		#expect(await coach.resetAndSettle(in: .main) == .started(memory: .saved))
		let requests = transport.requests
		#expect(requests.contains { $0.charge == .chatAttempt })
		#expect(requests.contains { $0.charge == .compaction })
		#expect(requests.contains { $0.charge == .memoryFlush })
		let builtIn = ModelCatalog.bundled.orderedEntries[0]
		#expect(
			requests.allSatisfy {
				$0.model == builtIn.id && $0.credential.method == .credits
					&& $0.provider == builtIn.details.provider
			})
		await coach.lifecycle(.willTerminate)
	}

	@Test func updatedHostAsksConsentOnceThenPinsTheWire() async throws {
		let builtIn = try projectBuiltInModel()
		let listed = try #require(catalog.entries[builtIn])
		let signedIn = try ModelCatalogEntry(
			id: builtIn,
			details: ModelDetails(
				displayName: listed.displayName,
				provider: NamedProvider(name: "DeepSeek", routingSlug: "deepseek")))
		try #require(signedIn.details.provider != listed.provider)
		let fixture = try secrets()
		let earlier = try ModelCatalog(revision: 1, entries: [signedIn])
		let records = InMemoryRecordLog()
		let before = await coach(
			fixture.store, transport: FakeModelTransport(respond: reply), records: records,
			catalog: earlier, builtIn: builtIn)
		#expect(
			try await before.observedStatus().acceptedConsent?.target
				== ConsentTarget(method: .credits, entry: signedIn))
		await before.lifecycle(.willTerminate)
		let bodies = Mutex<[JSONValue]>([])
		let models = try OpenRouterStub.models(catalog: .bundled) { request in
			do {
				let body = try #require(openRouterHTTPBody(from: request))
				let parsed = try JSONValue.parse(String(decoding: body, as: UTF8.self))
				bodies.withLock { $0.append(parsed) }
			} catch {
				Issue.record(error)
			}
			return .reply(
				.sse(
					#"data: {"choices":[{"delta":{"content":"Pinned."},"finish_reason":"stop"}]}"#
						+ "\ndata: [DONE]\n"))
		}
		let updated = makeCoach(
			records: RecordStore(log: records),
			secrets: try ICloudKeychainStore.fixture(directory: fixture.directory).store,
			models: models, clock: clock, builtInModel: builtIn)
		guard case .required(let challenge) = try await updated.observedStatus().access.consent
		else {
			Issue.record("An updated host must ask for consent before any message goes to it")
			return
		}
		#expect(challenge.target.method == .credits)
		#expect(challenge.target.entry.details == listed)
		#expect(
			failure(try await updated.sendAndSettle("Before agreeing to the new host"))
				== .model(.accessUnavailable(.providerConsentRequired)))
		#expect(bodies.withLock { $0.isEmpty })
		try await updated.recordConsent(challenge)
		#expect(replyText(try await updated.sendAndSettle("After agreeing")) == "Pinned.")
		let sent = try #require(bodies.withLock { $0.last }).objectFields
		#expect(sent["model"] == .string(builtIn.rawValue))
		#expect(
			sent["provider"]
				== .object([
					"only": .array([.string(listed.provider.routingSlug)]),
					"allow_fallbacks": .bool(false),
				]))
		await updated.lifecycle(.willTerminate)
		let reopened = makeCoach(
			records: RecordStore(log: records),
			secrets: try ICloudKeychainStore.fixture(directory: fixture.directory).store,
			models: models, clock: clock, builtInModel: builtIn)
		#expect(try await reopened.observedStatus().needsProviderConsent == false)
		await reopened.lifecycle(.willTerminate)
	}

	private var reply: FakeModelTransport.Response {
		{ request in ScriptedReply([.text(request.model.rawValue), .finish(reason: .stop)]) }
	}

	private func secrets() throws -> (
		directory: URL, store: ICloudKeychainStore, backing: FixtureSecretStoreBacking
	) {
		let directory = try TestTemporaryFolders.make()
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		let fixture = try ICloudKeychainStore.fixture(directory: directory)
		try fixture.store.storeCreditsAccount(
			CreditsAccount(appAccountToken: UUID(), key: creditsKey))
		return (directory, fixture.store, fixture.backing)
	}

	private func coach(
		_ secrets: any SecretStore, transport: FakeModelTransport,
		records: InMemoryRecordLog = InMemoryRecordLog(), catalog: ModelCatalog = .bundled,
		builtIn: ModelID = ModelCatalog.bundled.orderedEntries[0].id, consent: Bool = true
	) async -> Coach {
		let coach = makeCoach(
			records: RecordStore(log: records), secrets: secrets,
			models: .scripted(transport, catalog: catalog), clock: clock, builtInModel: builtIn)
		return consent ? await consentingCoach(coach) : coach
	}
}
