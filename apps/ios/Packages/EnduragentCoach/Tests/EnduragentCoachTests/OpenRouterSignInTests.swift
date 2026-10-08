import EnduragentCoachFixtures
import Foundation
import Security
import Testing

@testable import EnduragentCoach

@Suite(.timeLimit(.minutes(2))) struct OpenRouterSignInTests {
	private let creditsKey = "synthetic-sign-in-credits"
	private let oldKey = "synthetic-sign-in-old-account"
	private let newKey = "synthetic-sign-in-new-account"
	private let code = "synthetic-sign-in-code"
	private let catalog = ModelCatalog.bundled

	@Test(arguments: [false, true])
	func overlappingIntentsJoinAndSwitchOnlyAfterSave(openRouter: Bool) async throws {
		let fixture = try fixture(openRouter: openRouter)
		let authorizer = FakeOpenRouterAuthorizer(response: .held)
		let stub = exchange()
		let transport = transport()
		let records = InMemoryRecordLog()
		let coach = await coach(
			fixture.store, authorizer: authorizer, exchange: stub.exchange,
			transport: transport, records: records)
		let initial = try await coach.observedStatus().access
		let writes = fixture.backing.writeCount
		let first = Task { await coach.changeModelAccess(.signInToOpenRouter) }
		defer { first.cancel() }
		try await waitForAuthorizations(authorizer, count: 1)
		let second = Task { await coach.changeModelAccess(.signInToOpenRouter) }
		defer { second.cancel() }
		try await assertTurn(
			coach, transport: transport, key: openRouter ? oldKey : creditsKey,
			method: openRouter ? .openRouterAccount : .credits, model: try #require(initial.model))
		#expect(fixture.backing.writeCount == writes)
		#expect(stub.requests.recorded.isEmpty)
		#expect(try await coach.observedStatus().access == initial)
		await authorizer.complete(.success(OpenRouterAuthCode(code: code)), at: 0)
		let outcome = await first.value
		#expect(await second.value == outcome)
		guard case .replaced(let summary, _) = outcome,
			case .openRouterAccount(let choice) = summary.selection
		else {
			Issue.record("Joined sign-in must replace access once")
			return
		}
		#expect(await authorizer.requests.count == 1)
		#expect(stub.requests.recorded.count == 1)
		#expect(fixture.backing.writeCount == writes + 2)
		#expect(try fixture.store.openRouterAccountKey(at: choice.credential) == newKey)
		#expect(try fixture.store.openRouterAccountKey(at: fixture.oldReference) == oldKey)
		try await coach.recordConsent()
		try await assertTurn(
			coach, transport: transport, key: newKey,
			method: .openRouterAccount, model: try #require(initial.model))
		try await secretsNeverEnterEvidence(
			coach, records: records, outcome: outcome, stub: stub.requests)
	}

	@Test(arguments: [false, true])
	func firstSignInUsesCreditsModelAndResignInPreservesChoice(openRouter: Bool) async throws {
		let fixture = try fixture(openRouter: openRouter)
		let authorizer = FakeOpenRouterAuthorizer(response: .completed(.success(.init(code: code))))
		let stub = exchange()
		let transport = transport()
		let records = InMemoryRecordLog()
		let coach = await coach(
			fixture.store, authorizer: authorizer, exchange: stub.exchange,
			transport: transport, records: records)
		let initial = try await coach.observedStatus().access
		let model = try #require(initial.model)
		if !openRouter {
			#expect(model == catalog.orderedEntries.first?.id)
			try await assertTurn(
				coach, transport: transport, key: creditsKey, method: .credits, model: model)
		}
		let outcome = await coach.changeModelAccess(.signInToOpenRouter)
		guard case .replaced(let summary, _) = outcome,
			case .openRouterAccount(let choice) = summary.selection
		else {
			Issue.record("Expected a saved sign-in")
			return
		}
		#expect(choice.model == model)
		let saved = try #require(try fixture.store.accessSelection())
		#expect(
			saved
				== .init(
					.openRouter(
						SavedOpenRouterReference(
							credential: choice.credential, model: model,
							details: choice.entry.details))))
		try await coach.recordConsent()
		try await assertTurn(
			coach, transport: transport, key: newKey, method: .openRouterAccount, model: model)
		let reopened = try ICloudKeychainStore.fixture(directory: fixture.directory).store
		let next = await self.coach(
			reopened, authorizer: authorizer, exchange: stub.exchange,
			transport: transport, records: records)
		#expect(try await next.observedStatus().access.model == model)
		#expect(try reopened.openRouterAccountKey(at: choice.credential) == newKey)
		try await assertTurn(
			next, transport: transport, key: newKey, method: .openRouterAccount, model: model)
	}

	@Test(
		arguments: [false, true],
		["cancel", "callback", "presentation", "exchange", "key-write", "selection-write"])
	func failuresKeepExactPreviousAccessImmediatelyAndAfterReopen(openRouter: Bool, fault: String)
		async throws
	{
		let fixture = try fixture(openRouter: openRouter)
		let signInFailure: SignInFailure? =
			switch fault {
			case "cancel": .canceled
			case "callback": .callbackRejected
			case "presentation": .presentationUnavailable
			default: nil
			}
		let authorizer = FakeOpenRouterAuthorizer(
			response: .completed(
				signInFailure.map(Result.failure) ?? .success(.init(code: code))))
		let stub = exchange(failing: fault == "exchange")
		let transport = transport()
		let records = InMemoryRecordLog()
		let coach = await coach(
			fixture.store, authorizer: authorizer, exchange: stub.exchange,
			transport: transport, records: records)
		let previous = try await coach.observedStatus().access
		let selection = try fixture.store.accessSelection()
		let bytes = try fixture.backing.copy(account: CredentialSlot.accessSelection.rawValue)
		let writes = fixture.backing.writeCount
		if fault == "key-write" || fault == "selection-write" {
			fixture.backing.failWrites(
				fault == "key-write"
					? CredentialSlot.openRouterAccountKey.rawValue
					: CredentialSlot.accessSelection.rawValue,
				with: errSecNotAvailable)
		}
		let outcome = await coach.changeModelAccess(.signInToOpenRouter)
		let expected: CredentialFailure =
			signInFailure.map(CredentialFailure.signIn)
			?? (fault == "exchange"
				? .keyExchange(.http(status: 503)) : .secureStorage(.secureStorageUnavailable))
		#expect(
			outcome
				== .failedPreviousKept(
					expected, previous: previous.selection.map { AccessSummary(selection: $0) }))
		#expect(await authorizer.requests.count == 1)
		#expect(stub.requests.recorded.count == (signInFailure == nil ? 1 : 0))
		#expect(fixture.backing.writeCount == writes + (fault == "selection-write" ? 1 : 0))
		#expect(try fixture.store.accessSelection() == selection)
		#expect(try fixture.backing.copy(account: CredentialSlot.accessSelection.rawValue) == bytes)
		#expect(try fixture.store.openRouterAccountKey(at: fixture.oldReference) == oldKey)
		#expect(try fixture.store.creditsAccount()?.key == creditsKey)
		#expect(try await coach.observedStatus().access == previous)
		try await assertTurn(
			coach, transport: transport, key: openRouter ? oldKey : creditsKey,
			method: openRouter ? .openRouterAccount : .credits, model: try #require(previous.model))
		let reopened = try ICloudKeychainStore.fixture(directory: fixture.directory).store
		#expect(try reopened.accessSelection() == selection)
		#expect(try reopened.openRouterAccountKey(at: fixture.oldReference) == oldKey)
		#expect(try reopened.creditsAccount()?.key == creditsKey)
		let next = await self.coach(
			reopened, authorizer: authorizer, exchange: stub.exchange,
			transport: transport, records: records)
		#expect(try await next.observedStatus().access == previous)
		try await assertTurn(
			next, transport: transport, key: openRouter ? oldKey : creditsKey,
			method: openRouter ? .openRouterAccount : .credits, model: try #require(previous.model))
		try await secretsNeverEnterEvidence(
			coach, records: records, outcome: outcome, stub: stub.requests)
	}

	@Test(arguments: [
		ModelAccessChange.useCredits,
		.selectOpenRouterModel(ModelCatalog.bundled.orderedEntries[0].id), .disconnectOpenRouter,
	])
	func explicitChoiceInvalidatesHeldSignIn(_ change: ModelAccessChange) async throws {
		let fixture = try fixture(openRouter: change != .useCredits)
		let authorizer = FakeOpenRouterAuthorizer(response: .held)
		let stub = exchange()
		let coach = await coach(fixture.store, authorizer: authorizer, exchange: stub.exchange)
		let pending = Task { await coach.changeModelAccess(.signInToOpenRouter) }
		defer { pending.cancel() }
		try await waitForAuthorizations(authorizer, count: 1)
		_ = await coach.changeModelAccess(change)
		let selection = try fixture.store.accessSelection()
		let status = try await coach.observedStatus().access
		let writes = fixture.backing.writeCount
		await authorizer.complete(.success(.init(code: code)), at: 0)
		#expect(await pending.value == .kept(status.selection.map { AccessSummary(selection: $0) }))
		#expect(try fixture.store.accessSelection() == selection)
		#expect(try await coach.observedStatus().access == status)
		#expect(stub.requests.recorded.isEmpty)
		#expect(fixture.backing.writeCount == writes)
	}

	@Test func lateCompletionCannotReplaceNewerSignIn() async throws {
		let fixture = try fixture(openRouter: false)
		let authorizer = FakeOpenRouterAuthorizer(response: .held)
		let stub = exchange()
		let coach = await coach(fixture.store, authorizer: authorizer, exchange: stub.exchange)
		let older = Task { await coach.changeModelAccess(.signInToOpenRouter) }
		defer { older.cancel() }
		try await waitForAuthorizations(authorizer, count: 1)
		_ = await coach.changeModelAccess(.useCredits)
		let newer = Task { await coach.changeModelAccess(.signInToOpenRouter) }
		defer { newer.cancel() }
		try await waitForAuthorizations(authorizer, count: 2)
		await authorizer.complete(.success(.init(code: code)), at: 1)
		guard case .replaced = await newer.value else {
			Issue.record("New flight must save")
			return
		}
		let selection = try fixture.store.accessSelection()
		let status = try await coach.observedStatus().access
		await authorizer.complete(.success(.init(code: "synthetic-stale-code")), at: 0)
		#expect(await older.value == .kept(status.selection.map { AccessSummary(selection: $0) }))
		#expect(try fixture.store.accessSelection() == selection)
		#expect(stub.requests.recorded.count == 1)
		#expect(await authorizer.requests.count == 2)
	}

	@Test func syncedSelectionChangeInvalidatesHeldSignIn() async throws {
		let fixture = try fixture(openRouter: false)
		let authorizer = FakeOpenRouterAuthorizer(response: .held)
		let stub = exchange()
		let transport = transport()
		let coach = await coach(
			fixture.store, authorizer: authorizer, exchange: stub.exchange, transport: transport)
		let pending = Task { await coach.changeModelAccess(.signInToOpenRouter) }
		defer { pending.cancel() }
		try await waitForAuthorizations(authorizer, count: 1)
		let peer = fixture.backing.store()
		let entry = try #require(catalog.orderedEntries.last)
		let reference = OpenRouterCredentialRef.generation(UUID())
		try peer.storeOpenRouterAccountKey("synthetic-synced-key", at: reference)
		let selection = SavedAccessReference(
			.openRouter(
				SavedOpenRouterReference(
					credential: reference, model: entry.id, details: entry.details)))
		try peer.storeAccessSelection(selection)
		await authorizer.complete(.success(.init(code: code)), at: 0)
		guard case .kept = await pending.value else {
			Issue.record("Synced choice must win")
			return
		}
		#expect(try fixture.store.accessSelection() == selection)
		#expect(try peer.openRouterAccountKey(at: reference) == "synthetic-synced-key")
		#expect(stub.requests.recorded.isEmpty)
		try await coach.recordConsent()
		try await assertTurn(
			coach, transport: transport, key: "synthetic-synced-key", method: .openRouterAccount,
			model: entry.id)
	}

	private func fixture(openRouter: Bool) throws -> (
		directory: URL, store: ICloudKeychainStore, backing: FixtureSecretStoreBacking,
		oldReference: OpenRouterCredentialRef
	) {
		let directory = try TestTemporaryFolders.make()
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		let fixture = try ICloudKeychainStore.fixture(directory: directory)
		try fixture.store.storeCreditsAccount(.init(appAccountToken: UUID(), key: creditsKey))
		let reference = OpenRouterCredentialRef.generation(UUID())
		try fixture.store.storeOpenRouterAccountKey(oldKey, at: reference)
		let entry = try #require(catalog.orderedEntries.last)
		try fixture.store.storeAccessSelection(
			openRouter
				? .init(
					.openRouter(
						SavedOpenRouterReference(
							credential: reference, model: entry.id, details: entry.details)))
				: .init(.credits))
		return (directory, fixture.store, fixture.backing, reference)
	}

	private func exchange(failing: Bool = false) -> (
		exchange: OpenRouterKeyExchange, requests: OpenRouterRequestCapture
	) {
		let body =
			failing
			? #"{"error":"synthetic-sign-in-code synthetic-sign-in-new-account"}"#
			: #"{"key":"synthetic-sign-in-new-account"}"#
		return OpenRouterStub.keyExchange { _ in .reply(.json(failing ? 503 : 200, body)) }
	}

	private func transport() -> FakeModelTransport {
		FakeModelTransport()
	}

	private func coach(
		_ store: ICloudKeychainStore, authorizer: FakeOpenRouterAuthorizer,
		exchange: OpenRouterKeyExchange,
		transport: FakeModelTransport = FakeModelTransport(),
		records: InMemoryRecordLog = InMemoryRecordLog()
	) async -> Coach {
		let ports = CoachPorts(
			records: RecordStore(log: records), secrets: store,
			models: .scripted(transport, catalog: catalog),
			training: .fake { _, _ in
				FakeIntervalsClient(athleteName: "Synthetic Athlete", ftp: 250)
			},
			credits: .fake(FakeCreditsClient()), host: ImmediateExecutionHost(),
			clock: FixedClock(now: "1998-06-13T08:00:00+02:00", timeZone: "Europe/Amsterdam"),
			openRouterSignIn: .init(authorizer: authorizer, exchange: exchange))
		return await consentingCoach(
			Coach(
				sport: .cycling, ports: ports,
				builtInModel: catalog.orderedEntries[0].id, displayLocale: testDisplayLocale,
				coalescing: quickWindow))
	}

	private func assertTurn(
		_ coach: Coach, transport: FakeModelTransport, key: String, method: AccessMethod,
		model: ModelID
	) async throws {
		transport.respond = ScriptedReply.sequence([
			.toolCall(name: "memory_query", arguments: #"{"from":"1998-06-01","to":"1998-06-13"}"#),
			.finish(reason: .toolCalls), .text("Your notes are checked."), .finish(reason: .stop),
		])
		let before = transport.requestCount
		#expect(
			replyText(try await coach.sendAndSettle("Read my training notes"))
				== "Your notes are checked.")
		let requests = Array(transport.requests.dropFirst(before))
		#expect(requests.count == 2)
		#expect(
			requests.allSatisfy {
				$0.credential.secret == key && $0.credential.method == method
					&& $0.model == model
			})
		#expect(requests.last?.messages.contains { $0.role == .tool } == true)
	}

	private func waitForAuthorizations(_ authorizer: FakeOpenRouterAuthorizer, count: Int)
		async throws
	{
		let deadline = ContinuousClock.now + TestWaitLimit.hangGuard.duration
		while await authorizer.requests.count < count {
			guard ContinuousClock.now < deadline else { throw TestWaitDeadlineExceeded() }
			try await Task.sleep(for: .milliseconds(5))
		}
	}

	private func secretsNeverEnterEvidence(
		_ coach: Coach, records: InMemoryRecordLog,
		outcome: CredentialOutcome<AccessSummary>, stub: OpenRouterRequestCapture
	) async throws {
		var secrets = [creditsKey, oldKey, newKey, code]
		for request in stub.recorded {
			let body = try JSONDecoder().decode(
				[String: String].self, from: #require(request.httpBody))
			secrets.append(try #require(body["code_verifier"]))
		}
		let synced = try await records.fetch(RecordQuery(scope: .everySynced)).records
		let local = try await records.fetch(RecordQuery(scope: .everyDeviceLocal)).records
		let evidence =
			String(reflecting: coach.diagnostics.entries) + String(reflecting: synced)
			+ String(reflecting: local) + String(reflecting: outcome)
			+ String(reflecting: outcome.notice)
			+ String(reflecting: try await coach.observedStatus())
			+ String(reflecting: await coach.currentSnapshot(.main))
		#expect(!synced.isEmpty)
		for secret in secrets { #expect(!evidence.contains(secret)) }
	}
}
