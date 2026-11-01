import EnduragentCoachFixtures
import Foundation
import Security
import Synchronization
import Testing

@testable import EnduragentCoach

@Suite struct ModelChoiceTests {
	private let catalog = ModelCatalog.bundled
	private let clock = FixedClock(now: "1998-06-13T08:00:00+02:00", timeZone: "Europe/Amsterdam")
	private let accountKey = "synthetic-model-choice-account"
	private let creditsKey = "synthetic-model-choice-credits"

	@Test func bundledChoicesAnswerOfflineAndMatchCreditsBuildPolicy() async throws {
		let first = try #require(catalog.orderedEntries.first)
		let builtIn = try projectBuiltInModel()
		#expect(first.id == builtIn)
		let fixture = try secrets()
		let transport = FakeModelTransport(respond: reply)
		let coach = await coach(fixture.store, transport: transport, builtIn: builtIn)
		let statuses = await coach.observeStatus()
		let initial = try #require(try await statuses.status { _ in true }).access
		let offered = try #require(initial.modelChoices)
		#expect(offered.catalog.cache == .available(.bundled))
		#expect(offered.catalog.catalog.revision > 0)
		#expect(offered.catalog.catalog.orderedEntries.count >= 2)
		for entry in offered.catalog.catalog.orderedEntries {
			let selection = try await choose(entry.id, using: coach)
			let status = try #require(try await statuses.status { $0.access.model == entry.id })
			#expect(status.access.selection == selection)
			#expect(status.access.modelChoices?.selected == entry)
			#expect(
				replyText(try await coach.sendAndSettle("Which model answers?"))
					== entry.id.rawValue)
			let request = try #require(transport.requests.last)
			#expect(request.model == entry.id)
			#expect(request.provider == entry.details.provider)
			#expect(request.credential.method == .openRouterAccount)
		}
		#expect(
			await coach.changeModelAccess(.useCredits)
				== .replaced(AccessSummary(selection: .credits), authority: nil))
		#expect(try await coach.observedStatus().access.modelChoices == nil)
		try await coach.recordConsent()
		#expect(
			replyText(try await coach.sendAndSettle("Which model answers for Credits?"))
				== builtIn.rawValue)
		#expect(transport.requests.last?.model == first.id)
		await coach.lifecycle(.willTerminate)
	}

	@Test func chosenModelReopensWithDeviceLocalConsent() async throws {
		let fixture = try secrets()
		let selected = try #require(catalog.orderedEntries.last)
		let records = InMemoryRecordLog(deviceId: DeviceID(rawValue: "model-first-device"))
		let firstTransport = FakeModelTransport(respond: reply)
		let first = await coach(fixture.store, transport: firstTransport, records: records)
		_ = try await choose(selected.id, using: first)
		#expect(replyText(try await first.sendAndSettle("Use my choice")) == selected.id.rawValue)
		let saved = try await first.observedStatus().access
		await first.lifecycle(.willTerminate)
		let laterCatalog = try ModelCatalog(
			revision: 2, entries: [try #require(catalog.orderedEntries.first)])
		let reopened = try ICloudKeychainStore.fixture(directory: fixture.directory).store
		let transport = FakeModelTransport(respond: reply)
		let next = await coach(
			reopened, transport: transport, records: records, catalog: laterCatalog, consent: false)
		let reopenedStatus = try await next.observedStatus().access
		#expect(reopenedStatus.selection == saved.selection)
		#expect(reopenedStatus.modelChoices?.selected == selected)
		#expect(
			replyText(try await next.sendAndSettle("Use my saved choice")) == selected.id.rawValue)
		await next.lifecycle(.willTerminate)
		let secondRecords = InMemoryRecordLog(deviceId: DeviceID(rawValue: "model-second-device"))
		let firstConsent = try await records.fetch(
			RecordQuery(scope: .deviceLocal([.providerConsent])))
		try await secondRecords.append(firstConsent.records, locality: .deviceLocal)
		let synced = try ICloudKeychainStore.fixture(directory: fixture.directory).store
		let secondTransport = FakeModelTransport(respond: reply)
		let second = await coach(
			synced, transport: secondTransport, records: secondRecords, catalog: laterCatalog,
			consent: false)
		let secondStatus = try await second.observedStatus()
		#expect(secondStatus.access.selection == reopenedStatus.selection)
		#expect(secondStatus.access.modelChoices?.selected.details == selected.details)
		#expect(secondStatus.needsProviderConsent)
		#expect(
			failure(try await second.sendAndSettle("Use the synced model"))
				== .model(.accessUnavailable(.providerConsentRequired)))
		#expect(secondTransport.requestCount == 0)
		try await second.recordConsent()
		#expect(
			replyText(try await second.sendAndSettle("Use the synced model after consent"))
				== selected.id.rawValue)
		#expect(secondTransport.requests.last?.provider == selected.details.provider)
		await second.lifecycle(.willTerminate)
	}

	@Test func failedSelectionWriteKeepsThePreviousModel() async throws {
		let fixture = try secrets()
		let transport = FakeModelTransport(respond: reply)
		let records = InMemoryRecordLog()
		let coach = await coach(fixture.store, transport: transport, records: records)
		let previousStatus = try await coach.observedStatus()
		let previous = previousStatus.access
		let saved = try fixture.store.accessSelection()
		let consentQuery = RecordQuery(scope: .deviceLocal([.providerConsent]))
		let consent = try await records.fetch(consentQuery).records
		#expect(
			replyText(try await coach.sendAndSettle("Before the change"))
				== previous.model?.rawValue)
		let request = try #require(transport.requests.last)
		let requestCount = transport.requestCount
		let candidate = try #require(catalog.orderedEntries.last)
		fixture.backing.failWrites(
			CredentialSlot.accessSelection.rawValue, with: errSecNotAvailable)
		_ = await coach.changeModelAccess(.selectOpenRouterModel(candidate.id))
		let proposed = try await coach.observedStatus().access.consent
		guard case .required(let challenge) = proposed else {
			Issue.record("Expected provider consent before changing the saved model")
			return
		}
		await #expect(throws: ConsentWriteFailure.notSaved) {
			try await coach.recordConsent(challenge)
		}
		#expect(try await coach.observedStatus().access.model == previous.model)
		#expect(try fixture.store.accessSelection() == saved)
		#expect(try await records.fetch(consentQuery).records == consent)
		#expect(transport.requestCount == requestCount)
		await coach.declineConsent(challenge)
		#expect(try await coach.observedStatus().needsProviderConsent == false)
		#expect(try await coach.observedStatus().acceptedConsent == previousStatus.acceptedConsent)
		#expect(try await coach.observedStatus().access.selection == previous.selection)
		#expect(
			replyText(try await coach.sendAndSettle("Keep my previous model"))
				== previous.model?.rawValue)
		#expect(transport.requests.last?.model == request.model)
		await coach.lifecycle(.willTerminate)
		let reopened = try ICloudKeychainStore.fixture(directory: fixture.directory).store
		let next = await self.coach(
			reopened, transport: transport, records: records, consent: false)
		#expect(try await next.observedStatus().access.selection == previous.selection)
		#expect(try await next.observedStatus().needsProviderConsent == false)
		#expect(try await records.fetch(consentQuery).records == consent)
		#expect(
			replyText(try await next.sendAndSettle("Still keep my previous model"))
				== previous.model?.rawValue)
		#expect(transport.requests.last?.model == request.model)
		_ = try await choose(candidate.id, using: next)
		#expect(try await next.observedStatus().access.modelChoices?.selected == candidate)
		#expect(try await next.observedStatus().acceptedConsent?.target?.entry == candidate)
		#expect(
			replyText(try await next.sendAndSettle("Use the successful choice"))
				== candidate.id.rawValue)
		#expect(transport.requests.last?.model == candidate.id)
		await next.lifecycle(.willTerminate)
	}

	@Test func nonCatalogChoicesCannotBeSelectedOrInvoked() async throws {
		let fixture = try secrets()
		let transport = FakeModelTransport(respond: reply)
		let coach = await coach(fixture.store, transport: transport)
		let previous = try await coach.observedStatus().access
		let unknown = ModelID(rawValue: "unknown/not-published")
		#expect(
			await coach.changeModelAccess(.selectOpenRouterModel(unknown))
				== .refused(.modelNotInCatalog))
		#expect(try await coach.observedStatus().access == previous)
		#expect(
			replyText(try await coach.sendAndSettle("Keep the catalog model"))
				== previous.model?.rawValue)
		await coach.lifecycle(.willTerminate)
		try fixture.store.storeAccessSelection(
			.init(.openRouter(SavedOpenRouterReference(credential: .legacy, model: unknown))))
		let reopened = try ICloudKeychainStore.fixture(directory: fixture.directory).store
		let invalidTransport = FakeModelTransport(respond: reply)
		let invalid = await self.coach(reopened, transport: invalidTransport, consent: false)
		#expect(
			try await invalid.observedStatus().access.availability
				== .unavailable(.malformedStoredCredential(.accessSelection)))
		#expect(
			failure(try await invalid.sendAndSettle("Reject the unknown saved model"))
				== .model(.accessUnavailable(.malformedStoredCredential(.accessSelection))))
		#expect(invalidTransport.requestCount == 0)
		await invalid.lifecycle(.willTerminate)
	}

	@Test(arguments: [AccessMethod.credits, .openRouterAccount])
	func replyCompactionAndExtractionUseTheAccessModel(_ method: AccessMethod) async throws {
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
		let chosen = try #require(isolatedCatalog.orderedEntries.first)
		_ = try await choose(chosen.id, using: coach)
		if method == .credits {
			_ = await coach.changeModelAccess(.useCredits)
			try await coach.recordConsent()
		}
		#expect(
			replyText(try await coach.sendAndSettle("Check my training"))
				== "Your training is checked.")
		#expect(await coach.resetAndSettle(in: .main) == .started(memory: .saved))
		let requests = transport.requests
		#expect(requests.contains { $0.charge == .chatAttempt })
		#expect(requests.contains { $0.charge == .compaction })
		#expect(requests.contains { $0.charge == .memoryFlush })
		let model = method == .credits ? ModelCatalog.bundled.orderedEntries[0].id : chosen.id
		#expect(requests.allSatisfy { $0.model == model && $0.credential.method == method })
		let host =
			method == .credits
			? ModelCatalog.bundled.orderedEntries[0].details.provider : chosen.details.provider
		#expect(requests.allSatisfy { $0.provider == host })
		await coach.lifecycle(.willTerminate)
	}

	@Test(arguments: [AccessMethod.credits, .openRouterAccount])
	func updatedHostAsksConsentOnceThenPinsTheWire(_ method: AccessMethod) async throws {
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
		try fixture.store.installOpenRouterChoice(model: builtIn, key: accountKey, catalog: earlier)
		let records = InMemoryRecordLog()
		let before = await coach(
			fixture.store, transport: FakeModelTransport(respond: reply), records: records,
			catalog: earlier, builtIn: builtIn)
		if method == .credits {
			_ = await before.changeModelAccess(.useCredits)
			try await before.recordConsent()
		}
		#expect(try await before.observedStatus().acceptedConsent?.target?.method == method)
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
		#expect(challenge.target.method == method)
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

	private func choose(_ model: ModelID, using coach: Coach) async throws -> AccessSelection {
		let outcome = await coach.changeModelAccess(.selectOpenRouterModel(model))
		switch outcome {
		case .kept, .replaced: break
		case .failedPreviousKept, .refused, .disconnected:
			Issue.record("A bundled model must be selectable offline")
		}
		if try await coach.observedStatus().needsProviderConsent { try await coach.recordConsent() }
		return try #require(try await coach.observedStatus().access.selection)
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
		let first = try #require(catalog.orderedEntries.first)
		try fixture.store.installOpenRouterChoice(
			model: first.id, key: accountKey, catalog: catalog)
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
