import Foundation
import Security
import Testing

@testable import EnduragentCoach

extension CredentialVaultTests {
	@Test(
		arguments: [false, true], [errSecInteractionNotAllowed, errSecNotAvailable, errSecDecode])
	func athleteResolutionFailureKeepsConnectedUnresolvedAccount(
		failingWrite: Bool, statusCode: OSStatus
	) async throws {
		let memory = FixtureSecretStoreBacking()
		let secrets = ICloudKeychainStore(backing: memory)
		let unresolved = IntervalsConnection(
			id: testConnection.id, credential: testConnection.credential,
			selection: .keyOwner, resolvedAthlete: nil)
		try secrets.storeCreditsAccount(CreditsAccount(appAccountToken: UUID(), key: testKey))
		try secrets.storeIntervalsConnection(unresolved)
		let gate = CredentialProfileGate()
		let client = GatedProfileIntervals(base: ada, gate: gate)
		let coach = coachWithTraining(secrets, training: TrainingService { _, _, _ in client })
		let status = Task { await coach.status() }
		await gate.waitUntilEntered()
		if failingWrite {
			memory.failWrites("intervalsCredential", with: statusCode)
		} else {
			memory.fail("intervalsCredential", with: statusCode)
		}
		await gate.release()
		let training = await status.value.training
		#expect(training == .connected(adaSummary, account: try account(unresolved)))
		if statusCode != errSecInteractionNotAllowed {
			#expect(
				coach.diagnostics.entries.map(\.event) == [
					.secureStorageFailed(
						.intervalsConnection,
						detail: String(describing: KeychainStoreError(status: statusCode)))
				])
		} else {
			#expect(coach.diagnostics.entries.isEmpty)
		}
		memory.fail("intervalsCredential", with: nil)
		memory.failWrites("intervalsCredential", with: nil)
		#expect(try secrets.intervalsConnection() == unresolved)
		guard case .connected = await coach.status().training else {
			Issue.record("expected the connection to resolve after unlock")
			return
		}
		#expect(
			try secrets.intervalsConnection()?.resolvedAthlete == testConnection.resolvedAthlete)
	}

	@Test func malformedItemDuringAthleteResolutionRecordsDiagnosticAndKeepsConnected()
		async throws
	{
		let memory = FixtureSecretStoreBacking()
		let secrets = ICloudKeychainStore(backing: memory)
		let unresolved = IntervalsConnection(
			id: testConnection.id, credential: testConnection.credential,
			selection: .keyOwner, resolvedAthlete: nil)
		try secrets.storeCreditsAccount(CreditsAccount(appAccountToken: UUID(), key: testKey))
		try secrets.storeIntervalsConnection(unresolved)
		let gate = CredentialProfileGate()
		let client = GatedProfileIntervals(base: ada, gate: gate)
		let coach = coachWithTraining(secrets, training: TrainingService { _, _, _ in client })
		let status = Task { await coach.status() }
		await gate.waitUntilEntered()
		try memory.update(account: "intervalsCredential", data: Data([0xFF, 0xFE, 0xFD]))
		await gate.release()
		#expect(
			await status.value.training == .connected(adaSummary, account: try account(unresolved)))
		#expect(
			coach.diagnostics.entries.map(\.event) == [
				.secureStorageFailed(
					.intervalsConnection,
					detail: String(describing: KeychainStoreError(status: errSecDecode)))
			])
		#expect(memory.writes(to: "intervalsCredential") == 2)
	}

	@Test func recoveryWriteFailureKeepsPreviousCredential() async throws {
		let memory = FixtureSecretStoreBacking()
		let secrets = ICloudKeychainStore(backing: memory)
		let oldToken = UUID()
		try secrets.storeCreditsAccount(
			CreditsAccount(
				appAccountToken: oldToken,
				key: "test-old-credits-key"))
		memory.failWrites(CredentialSlot.creditsAccount.rawValue, with: errSecNotAvailable)
		let coach = try recoveryCoach(secrets)
		await #expect(throws: AccessUnavailable.secureStorageUnavailable) {
			try await coach.credits.recover(signedTransaction: "test.signed.transaction")
		}
		#expect(try secrets.creditsAccount()?.appAccountToken == oldToken)
		#expect(try secrets.creditsAccount()?.key == "test-old-credits-key")
		_ = try await claimAccount(after: "Is Thursday on?", on: coach)
		#expect(transport.requests.last?.credential.secret == "test-old-credits-key")
	}

	@Test func oldProposalCannotExecuteForTheNewAthlete() async throws {
		let secrets = keyedSecrets()
		let coach = coach(secrets)
		let pending = try await proposeRide(on: coach)
		#expect(await coach.decide(.presented(pending.ref), in: .main) == .presentationRecorded)
		let token = try #require(await coach.currentSnapshot(.main)?.review?.token)
		_ = await coach.status()
		#expect(await coach.currentSnapshot(.main)?.review?.token == token)
		_ = await coach.changeTraining(
			.replaceConfirmingAthleteSwitch(apiKey: "other-athlete", athlete: .keyOwner))
		#expect(await coach.currentSnapshot(.main)?.review?.controls == ReviewControls.none)
		#expect(await coach.currentSnapshot(.main)?.review?.notice?.kind == .accountChanged)
		let outcome = await coach.decide(.approve(token), in: .main)
		#expect(outcome == .blocked(.accountChanged))
		#expect(
			!bo.calls.contains { call in
				if case .createEvent = call { return true }
				return false
			})
	}

	@Test func sameAthleteRotationPreservesProposal() async throws {
		let secrets = keyedSecrets()
		let coach = coach(secrets)
		let pending = try await proposeRide(on: coach)
		#expect(await coach.decide(.presented(pending.ref), in: .main) == .presentationRecorded)
		let token = try #require(await coach.currentSnapshot(.main)?.review?.token)
		let original = try #require(try secrets.intervalsConnection())
		_ = await coach.changeTraining(.replace(apiKey: "same-athlete-new-key", athlete: .keyOwner))
		let current = try #require(try secrets.intervalsConnection())
		#expect(current.resolvedAthlete == testConnection.resolvedAthlete)
		#expect(current.id != testConnection.id)
		#expect(try account(original).authority(under: account(current)) == .sameAthlete)
		#expect(await coach.currentSnapshot(.main)?.review?.token == token)
		#expect(
			await coach.decide(.approve(token), in: .main)
				== .applied([ReviewReceipt(index: 0, result: .confirmed(eventId: "1"))]))
		#expect(
			ada.calls.contains {
				if case .createEvent = $0 { return true }
				return false
			})
	}

	@Test func resolvingTheSameConnectionPreservesProposal() async throws {
		let secrets = keyedSecrets()
		try secrets.storeIntervalsConnection(
			IntervalsConnection(
				id: testConnection.id, credential: testConnection.credential,
				selection: .keyOwner, resolvedAthlete: nil))
		let coach = coach(secrets)
		let pending = try await proposeRide(on: coach)
		#expect(await coach.decide(.presented(pending.ref), in: .main) == .presentationRecorded)
		let token = try #require(await coach.currentSnapshot(.main)?.review?.token)
		let original = try #require(try secrets.intervalsConnection())
		_ = await coach.status()
		let current = try #require(try secrets.intervalsConnection())
		#expect(current.id == testConnection.id)
		#expect(current.resolvedAthlete != nil)
		#expect(try account(original).authority(under: account(current)) == .same)
		#expect(await coach.currentSnapshot(.main)?.review?.token == token)
		#expect(
			await coach.decide(.approve(token), in: .main)
				== .applied([ReviewReceipt(index: 0, result: .confirmed(eventId: "1"))]))
		#expect(
			ada.calls.contains {
				if case .createEvent = $0 { return true }
				return false
			})
	}

	@Test func unresolvedProposalCannotFollowAReplacementConnection() async throws {
		let secrets = keyedSecrets()
		try secrets.storeIntervalsConnection(
			IntervalsConnection(
				id: testConnection.id, credential: testConnection.credential,
				selection: .keyOwner, resolvedAthlete: nil))
		let coach = coach(secrets)
		let pending = try await proposeRide(on: coach)
		#expect(await coach.decide(.presented(pending.ref), in: .main) == .presentationRecorded)
		let token = try #require(await coach.currentSnapshot(.main)?.review?.token)
		let original = try #require(try secrets.intervalsConnection())
		_ = await coach.changeTraining(
			.replaceConfirmingAthleteSwitch(apiKey: "same-athlete-new-key", athlete: .keyOwner))
		let current = try #require(try secrets.intervalsConnection())
		#expect(current.id != testConnection.id)
		#expect(current.resolvedAthlete == testConnection.resolvedAthlete)
		#expect(try account(original).authority(under: account(current)) == .unverifiable)
		#expect(await coach.currentSnapshot(.main)?.review?.controls == ReviewControls.none)
		#expect(await coach.currentSnapshot(.main)?.review?.notice?.kind == .accountChanged)
		#expect(await coach.decide(.approve(token), in: .main) == .blocked(.accountChanged))
		#expect(
			!ada.calls.contains {
				if case .createEvent = $0 { return true }
				return false
			})
	}

	@Test func credentialsRetryAfterUnlock() async throws {
		let backing = FixtureSecretStoreBacking()
		let secrets = keyedSecrets(backing: backing)
		backing.locked = true
		let coach = coach(secrets)
		#expect(await coach.status().setup == .accessTemporarilyUnavailable(.secureStorageLocked))
		backing.locked = false
		await coach.lifecycle(.becameActive)
		#expect(await coach.status().setup == .ready)
	}

	@Test func concurrentReplacementThenDisconnectKeepsDisconnect() async throws {
		let secrets = keyedSecrets()
		let gate = CredentialProfileGate()
		let client = GatedProfileIntervals(base: ada, gate: gate)
		let service = TrainingService { credential, _, _ in
			if credential == .apiKey("test-delayed-key") { return client }
			return self.ada
		}
		let coach = coachWithTraining(secrets, training: service)
		let replacement = Task {
			await coach.changeTraining(.replace(apiKey: "test-delayed-key", athlete: .keyOwner))
		}
		await gate.waitUntilEntered()
		let disconnect = Task { await coach.changeTraining(.disconnect) }
		try await Task.sleep(for: .milliseconds(150))
		await gate.release()
		_ = await replacement.value
		#expect(await disconnect.value == .disconnected)
		#expect(try secrets.intervalsConnection() == nil)
		#expect(await coach.status().training == .unconnected)
		#expect(try await claimAccount(after: "Is Thursday on?", on: coach) == .unconnected)
	}

	@Test func oldProfileReadDoesNotOverwriteReplacement() async throws {
		let secrets = keyedSecrets()
		try secrets.storeIntervalsConnection(
			IntervalsConnection(
				id: testConnection.id, credential: .apiKey("test-unresolved"),
				selection: .keyOwner, resolvedAthlete: nil))
		let gate = CredentialProfileGate()
		let old = GatedProfileIntervals(base: ada, gate: gate)
		let service = TrainingService { credential, _, _ in
			if credential == .apiKey("test-unresolved") { return old }
			return self.bo
		}
		let coach = coachWithTraining(secrets, training: service)
		let status = Task { await coach.status() }
		await gate.waitUntilEntered()
		_ = await coach.changeTraining(.replace(apiKey: "other-athlete", athlete: .keyOwner))
		let replacement = try #require(try secrets.intervalsConnection())
		await gate.release()
		_ = await status.value
		#expect(try secrets.intervalsConnection() == replacement)
		#expect(try await claimAccount(after: "Is Thursday on?", on: coach) == account(replacement))
	}

	private func recoveryCoach(_ secrets: any SecretStore, training service: TrainingService? = nil)
		throws -> Coach
	{
		let config = URLSessionConfiguration.ephemeral
		config.protocolClasses = [RecoveryResponseStub.self]
		let session = URLSession(configuration: config)
		let base = try #require(URL(string: "https://credits.invalid"))
		return Coach(
			sport: .cycling,
			ports: CoachPorts(
				records: RecordStore(log: records), secrets: secrets, models: .scripted(transport),
				training: service ?? training,
				credits: CreditsService { vault in
					PhoneCreditsClient(vault: vault, workerBase: base, session: session)
				},
				host: ImmediateExecutionHost(), clock: clock),
			builtInModel: testModel, deviceLanguage: .en,
			coalescing: quickWindow)
	}

	private func coachWithTraining(_ secrets: any SecretStore, training: TrainingService) -> Coach {
		Coach(
			sport: .cycling,
			ports: CoachPorts(
				records: RecordStore(log: records), secrets: secrets, models: .scripted(transport),
				training: training, credits: .fake(FakeCreditsClient()),
				host: ImmediateExecutionHost(), clock: clock),
			builtInModel: testModel, deviceLanguage: .en,
			coalescing: quickWindow)
	}
}

private final class RecoveryResponseStub: URLProtocol, @unchecked Sendable {
	override class func canInit(with request: URLRequest) -> Bool { true }
	override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
	override func startLoading() {
		guard let url = request.url,
			let response = HTTPURLResponse(
				url: url, statusCode: 200, httpVersion: nil,
				headerFields: ["Content-Type": "application/json"])
		else {
			client?.urlProtocol(self, didFailWithError: URLError(.badURL))
			return
		}
		let body =
			#"{"kind":"recovered","athleteId":"aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee","key":"test-new-credits-key","credits":150}"#
		client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
		client?.urlProtocol(self, didLoad: Data(body.utf8))
		client?.urlProtocolDidFinishLoading(self)
	}
	override func stopLoading() {}
}

private actor CredentialProfileGate {
	private var entered = false
	private var released = false
	private var waiters: [CheckedContinuation<Void, Never>] = []
	private var blocked: [CheckedContinuation<Void, Never>] = []

	func pause() async {
		entered = true
		for waiter in waiters { waiter.resume() }
		waiters.removeAll()
		if !released { await withCheckedContinuation { blocked.append($0) } }
	}

	func waitUntilEntered() async {
		if !entered { await withCheckedContinuation { waiters.append($0) } }
	}

	func release() {
		released = true
		for waiter in blocked { waiter.resume() }
		blocked.removeAll()
	}
}

private struct GatedProfileIntervals: IntervalsClient {
	let base: FakeIntervalsClient
	let gate: CredentialProfileGate

	func fetchAthlete() async throws -> AthleteProfile {
		await gate.pause()
		return try await base.fetchAthlete()
	}
	func fetchWellness(oldest: CivilDate, newest: CivilDate) async throws -> [WellnessDay] {
		try await base.fetchWellness(oldest: oldest, newest: newest)
	}
	func fetchActivities(oldest: CivilDate, newest: CivilDate) async throws -> [ActivitySummary] {
		try await base.fetchActivities(oldest: oldest, newest: newest)
	}
	func fetchActivity(id: ActivityID) async throws -> JSONValue {
		try await base.fetchActivity(id: id)
	}
	func fetchStreams(id: ActivityID) async throws -> JSONValue {
		try await base.fetchStreams(id: id)
	}
	func listEvents(oldest: CivilDate, newest: CivilDate) async throws -> [CalendarEvent] {
		try await base.listEvents(oldest: oldest, newest: newest)
	}
	func createChatEvent(_ draft: ChatCalendarCreate) async throws -> CalendarEvent {
		try await base.createChatEvent(draft)
	}
	func updateEvent(id: EventID, name: String?, description: String?, date: CivilDate?)
		async throws -> CalendarEvent
	{
		try await base.updateEvent(id: id, name: name, description: description, date: date)
	}
	func deleteEvent(id: EventID) async throws { try await base.deleteEvent(id: id) }
}
