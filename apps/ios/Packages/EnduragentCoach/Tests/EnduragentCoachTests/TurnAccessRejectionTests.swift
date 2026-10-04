import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

extension TurnAccessTests {
	private var rejectedKey: String { "synthetic-rejected-openrouter-key" }

	@Test func missingOpenRouterKeyOffersAccessWithoutRequest() async throws {
		let secrets = try openRouterSecrets()
		try secrets.deleteOpenRouterAccountKey(at: .legacy)
		let coach = await recoveryCoach(secrets)
		let settled = try await coach.sendAndSettle("Keep the conversation")
		#expect(failure(settled) == .model(.accessUnavailable(.notConfigured(.openRouterAccount))))
		#expect(turnNotice(of: settled)?.action == .chooseAccessMethod)
		#expect(try await coach.observedStatus().access.attention == .signInNeeded)
		#expect(transport.requestCount == 0)
	}

	@Test func rejectedKeyStaysQuarantinedAfterReopen() async throws {
		let directory = try TestTemporaryFolders.make()
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		let fixture = try ICloudKeychainStore.fixture(directory: directory)
		try installOpenRouter(fixture.store)
		transport.respond = { _ in ScriptedReply([.fail(.http(status: 401))]) }
		let coach = await recoveryCoach(fixture.store)
		let turn = try #require(
			try await coach.send(draft("Keep this message"), to: .main).acceptedTurn)
		let settled = try #require(await coach.settledState(of: turn, in: .main))
		#expect(failure(settled) == .model(.credentialRejected(.openRouterAccount)))
		#expect(turnNotice(of: settled)?.action == nil)
		#expect(transport.requestCount == 1)
		#expect(try await coach.observedStatus().access.attention == .rejectedKey)
		#expect(try await coach.observedStatus().access.notice?.action == .signInToOpenRouter)
		#expect(
			failure(try await coach.sendAndSettle("Another question"))
				== .model(.accessUnavailable(.openRouterKeyRejected)))
		#expect(transport.requestCount == 1)
		await coach.lifecycle(.willTerminate)
		let reopened = try ICloudKeychainStore.fixture(directory: directory).store
		let next = await recoveryCoach(reopened)
		#expect(try await next.observedStatus().access.attention == .rejectedKey)
		#expect(await next.state(of: turn) == settled)
		#expect(await next.currentSnapshot(.main)?.turns.first?.athleteText == "Keep this message")
		#expect(
			failure(try await next.sendAndSettle("After reopening"))
				== .model(.accessUnavailable(.openRouterKeyRejected)))
		_ = await next.resetAndSettle(in: .main)
		#expect(transport.requestCount == 1)
		let markers = try await store.fetch(
			RecordQuery(scope: .deviceLocal([.openRouterKeyRejected])))
		#expect(markers.records.count == 1)
		let row = try StoredAthleteRecord(record: try #require(markers.records.first))
		#expect(try row.decode().get().body == .deviceLocal(.openRouterKeyRejected(.legacy)))
		#expect(!String(decoding: row.body, as: UTF8.self).contains(rejectedKey))
	}

	@Test func overlappingRejectionsRecoverOnce() async throws {
		let backing = FixtureSecretStoreBacking()
		let secrets = ICloudKeychainStore(backing: backing)
		try installOpenRouter(secrets)
		let authorizer = FakeOpenRouterAuthorizer(response: .held)
		let gate = FakeModelGate(requiredArrivals: 2)
		transport.respond = { _ in ScriptedReply([.fail(.http(status: 401))], gate: gate) }
		let coach = await recoveryCoach(secrets, authorizer: authorizer)
		let first = try #require(
			try await coach.send(draft("First question"), to: .main).acceptedTurn)
		let peer: ChatID = "synthetic-concurrent-rejection"
		let second = try #require(
			try await coach.send(draft("Second question"), to: peer).acceptedTurn)
		let states = [
			try #require(await coach.settledState(of: first, in: .main)),
			try #require(await coach.settledState(of: second, in: peer)),
		]
		#expect(await gate.arrivals == 2)
		#expect(transport.requestCount == 2)
		#expect(
			states.allSatisfy { failure($0) == .model(.credentialRejected(.openRouterAccount)) })
		#expect(states.allSatisfy { turnNotice(of: $0)?.action == nil })
		#expect(try await coach.observedStatus().access.notice?.action == .signInToOpenRouter)
		#expect(
			try await store.fetch(RecordQuery(scope: .deviceLocal([.openRouterKeyRejected])))
				.records.count == 1)
		let writes = backing.writeCount
		let one = Task { await coach.changeModelAccess(.signInToOpenRouter) }
		let two = Task { await coach.changeModelAccess(.signInToOpenRouter) }
		defer {
			one.cancel()
			two.cancel()
		}
		try await waitForAuthorization(authorizer)
		await authorizer.complete(.success(.init(code: "synthetic-recovery-code")), at: 0)
		#expect(await one.value == two.value)
		#expect(await authorizer.requests.count == 1)
		#expect(backing.writeCount == writes + 2)
		#expect(try await coach.observedStatus().access.attention == nil)
		transport.respond = { _ in
			ScriptedReply([.text("Recovered in the same conversation"), .finish(reason: .stop)])
		}
		#expect(
			replyText(try await coach.sendAndSettle("Recovered question"))
				== "Recovered in the same conversation")
		let request = try #require(transport.requests.last)
		#expect(request.credential.secret == "fixture-signed-in-openrouter-key")
		#expect(request.credential.method == .openRouterAccount)
		#expect(request.model == testModel)
		#expect(await coach.currentSnapshot(.main)?.turns.first?.id == first)
		#expect(await coach.currentSnapshot(.main)?.turns.first?.athleteText == "First question")
	}

	@Test func forbiddenRequestKeepsTheKeyUsable() async throws {
		let secrets = try openRouterSecrets()
		transport.respond = { _ in ScriptedReply([.fail(.http(status: 403))]) }
		let coach = await recoveryCoach(secrets)
		let settled = try await coach.sendAndSettle("Blocked question")
		#expect(failure(settled) == .model(.requestBlocked))
		let notice = try #require(turnNotice(of: settled))
		#expect(
			notice.canonicalSentence
				== "OpenRouter blocked this request. Try a different model or message.")
		#expect(notice.action == nil)
		#expect(transport.requestCount == 1)
		#expect(try await coach.observedStatus().access.attention == nil)
		#expect(try await coach.observedStatus().access.availability == .ready)
		#expect(
			try await store.fetch(RecordQuery(scope: .deviceLocal([.openRouterKeyRejected])))
				.records.isEmpty)
		transport.respond = { _ in
			ScriptedReply([.text("A different message works"), .finish(reason: .stop)])
		}
		#expect(
			replyText(try await coach.sendAndSettle("Different message"))
				== "A different message works")
		#expect(
			transport.requests.allSatisfy {
				$0.credential.secret == rejectedKey && $0.credential.method == .openRouterAccount
			})
	}

	@Test(arguments: [false, true])
	func rejectionStorageFailureBlocksFurtherInvocations(readFailure: Bool) async throws {
		let directory = try TestTemporaryFolders.make()
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		let secrets = try ICloudKeychainStore.fixture(directory: directory).store
		try installOpenRouter(secrets)
		let faults = FaultInjectingRecordLog(wrapping: store)
		let coach = await recoveryCoach(secrets, records: faults)
		if readFailure {
			faults.failNextFetch(in: .deviceLocal([.openRouterKeyRejected]))
		}
		transport.respond = { _ in
			if !readFailure { faults.failNextAppend = true }
			return ScriptedReply([.fail(.http(status: 401))])
		}
		#expect(
			failure(try await coach.sendAndSettle("Storage failed"))
				== .model(.accessUnavailable(.recordStorageUnavailable)))
		#expect(transport.requestCount == (readFailure ? 0 : 1))
		if !readFailure {
			#expect(
				failure(try await coach.sendAndSettle("Still blocked"))
					== .model(.accessUnavailable(.openRouterKeyRejected)))
			#expect(transport.requestCount == 1)
			#expect(try await coach.observedStatus().access.attention == .rejectedKey)
			let markers = try await store.fetch(
				RecordQuery(scope: .deviceLocal([.openRouterKeyRejected])))
			#expect(markers.records.map(\.body) == [.deviceLocal(.openRouterKeyRejected(.legacy))])
			await coach.lifecycle(.willTerminate)
			let reopened = try ICloudKeychainStore.fixture(directory: directory).store
			let next = await recoveryCoach(reopened)
			#expect(try await next.observedStatus().access.attention == .rejectedKey)
			#expect(try await next.observedStatus().access.notice?.action == .signInToOpenRouter)
			#expect(await next.currentSnapshot(.main)?.turns.first?.athleteText == "Storage failed")
			#expect(
				failure(try await next.sendAndSettle("After storage recovery and reopening"))
					== .model(.accessUnavailable(.openRouterKeyRejected)))
			#expect(transport.requestCount == 1)
		}
	}

	@Test(arguments: [false, true])
	func rejectionBlocksAlreadyResolvedToolContinuation(recoverBeforeRelease: Bool) async throws {
		let secrets = try openRouterSecrets()
		let gate = FakeModelGate()
		transport.respond = { request in
			if request.text == "Held tool question" {
				return ScriptedReply(
					[
						.toolCall(
							name: "memory_query",
							arguments: #"{"from":"1998-01-01","to":"1998-06-13"}"#),
						.finish(reason: .toolCalls),
					], gate: gate)
			}
			return ScriptedReply([.fail(.http(status: 401))])
		}
		let coach = await recoveryCoach(
			secrets,
			authorizer: FakeOpenRouterAuthorizer(
				response: .completed(.success(.init(code: "synthetic-late-rejection-recovery")))))
		let main = try #require(
			try await coach.send(draft("Held tool question"), to: .main).acceptedTurn)
		let deadline = ContinuousClock.now + TestWaitLimit.hangGuard.duration
		while await gate.arrivals == 0, ContinuousClock.now < deadline {
			try await Task.sleep(for: .milliseconds(20))
		}
		try #require(await gate.arrivals == 1)
		#expect(
			failure(try await coach.sendAndSettle("Reject elsewhere", in: "synthetic-other-intent"))
				== .model(.credentialRejected(.openRouterAccount)))
		if recoverBeforeRelease {
			_ = await coach.changeModelAccess(.signInToOpenRouter)
		}
		await gate.release()
		#expect(
			failure(try #require(await coach.settledState(of: main, in: .main)))
				== .model(.accessUnavailable(.openRouterKeyRejected)))
		#expect(transport.requestCount == 2)
		if recoverBeforeRelease {
			#expect(try await coach.observedStatus().access.attention == nil)
			transport.respond = { _ in
				ScriptedReply([.text("New generation still works"), .finish(reason: .stop)])
			}
			#expect(
				replyText(try await coach.sendAndSettle("Use the new key"))
					== "New generation still works")
			#expect(
				transport.requests.last?.credential.secret == "fixture-signed-in-openrouter-key")
		}
	}

	private func installOpenRouter(_ secrets: ICloudKeychainStore) throws {
		try secrets.storeCreditsAccount(.init(appAccountToken: UUID(), key: testKey))
		try secrets.installOpenRouterChoice(model: testModel, key: rejectedKey)
	}

	private func openRouterSecrets() throws -> ICloudKeychainStore {
		let backing = FixtureSecretStoreBacking()
		let secrets = ICloudKeychainStore(backing: backing)
		try installOpenRouter(secrets)
		return secrets
	}

	private func recoveryCoach(
		_ secrets: ICloudKeychainStore,
		authorizer: FakeOpenRouterAuthorizer = FakeOpenRouterAuthorizer(),
		records: (any RecordLog)? = nil
	) async -> Coach {
		let coach = Coach(
			sport: .cycling,
			ports: CoachPorts(
				records: RecordStore(log: records ?? store), secrets: secrets,
				models: .scripted(transport),
				training: .fake { _, _ in FakeIntervalsClient(athleteName: "Ada", ftp: 250) },
				credits: .fake(FakeCreditsClient()), host: ImmediateExecutionHost(), clock: clock,
				openRouterSignIn: .fake(authorizer: authorizer)),
			builtInModel: testModel, displayLocale: testDisplayLocale, coalescing: quickWindow)
		return await consentingCoach(coach)
	}

	private func waitForAuthorization(_ authorizer: FakeOpenRouterAuthorizer) async throws {
		let deadline = ContinuousClock.now + TestWaitLimit.hangGuard.duration
		while await authorizer.requests.isEmpty, ContinuousClock.now < deadline {
			try await Task.sleep(for: .milliseconds(20))
		}
		try #require(await authorizer.requests.count == 1)
	}
}
