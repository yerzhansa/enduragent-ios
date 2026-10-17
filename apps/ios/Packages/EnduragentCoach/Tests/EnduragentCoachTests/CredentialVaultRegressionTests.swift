import EnduragentCoachFixtures
import Foundation
import Security
import Testing

@testable import EnduragentCoach

extension CredentialVaultTests {
	@Test(
		arguments: [false, true], [errSecInteractionNotAllowed, errSecNotAvailable, errSecDecode])
	func athleteResolutionFailurePreservesStoredItemAndReportsReadFailures(
		failingWrite: Bool, statusCode: OSStatus
	) async throws {
		let memory = FixtureSecretStoreBacking()
		let secrets = ICloudKeychainStore(backing: memory)
		let unresolved = IntervalsConnection(
			id: testConnection.id, credential: testConnection.credential,
			selection: .keyOwner, resolvedAthlete: nil)
		try secrets.storeCreditsAccount(CreditsAccount(appAccountToken: UUID(), key: testKey))
		try secrets.storeIntervalsConnection(unresolved)
		let ada = self.ada
		let gate = ada.hold(.profile)
		let coach = await coach(
			secrets, training: TrainingService { _, _ in ada })
		let status = Task { try await coach.refreshedStatus() }
		defer { status.cancel() }
		try #require(
			try await beforeDeadline(within: .hangGuard, onTimeout: { status.cancel() }) {
				await gate.waitUntilEntered()
			} != nil)
		if failingWrite {
			memory.failWrites("intervalsCredential", with: statusCode)
		} else {
			memory.fail("intervalsCredential", with: statusCode)
		}
		await gate.release()
		let resolved = try #require(
			try await beforeDeadline(within: .hangGuard, onTimeout: { status.cancel() }) {
				try await status.value
			})
		let training = resolved.training
		if failingWrite {
			#expect(training == .connected(adaSummary, account: account(testConnection)))
		} else {
			let failure: AccessUnavailable =
				statusCode == errSecInteractionNotAllowed
				? .secureStorageLocked
				: statusCode == errSecDecode
					? .malformedStoredCredential(.intervalsConnection) : .secureStorageUnavailable
			#expect(training == .unavailable(failure))
		}
		if statusCode != errSecInteractionNotAllowed {
			let events = coach.diagnostics.entries.map(\.event)
			#expect(!events.isEmpty)
			#expect(
				events.allSatisfy {
					$0
						== .secureStorageFailed(
							.intervalsConnection, failure: KeychainStoreError.keychain(statusCode))
				})
		} else {
			#expect(coach.diagnostics.entries.isEmpty)
		}
		memory.fail("intervalsCredential", with: nil)
		memory.failWrites("intervalsCredential", with: nil)
		#expect(try secrets.intervalsConnection() == unresolved)
		guard case .connected = try await coach.refreshedStatus().training else {
			Issue.record("expected the connection to resolve after unlock")
			return
		}
		#expect(
			try secrets.intervalsConnection()?.resolvedAthlete == testConnection.resolvedAthlete)
	}

	@Test func malformedItemDuringAthleteResolutionRecordsDiagnosticAndPreservesItem()
		async throws
	{
		let memory = FixtureSecretStoreBacking()
		let secrets = ICloudKeychainStore(backing: memory)
		let unresolved = IntervalsConnection(
			id: testConnection.id, credential: testConnection.credential,
			selection: .keyOwner, resolvedAthlete: nil)
		try secrets.storeCreditsAccount(CreditsAccount(appAccountToken: UUID(), key: testKey))
		try secrets.storeIntervalsConnection(unresolved)
		let ada = self.ada
		let gate = ada.hold(.profile)
		let coach = await coach(
			secrets, training: TrainingService { _, _ in ada })
		let status = Task { try await coach.refreshedStatus() }
		try #require(
			try await beforeDeadline(within: .hangGuard, onTimeout: { status.cancel() }) {
				await gate.waitUntilEntered()
			} != nil)
		try memory.update(account: "intervalsCredential", data: Data([0xFF, 0xFE, 0xFD]))
		await gate.release()
		#expect(
			try await status.value.training
				== .unavailable(.malformedStoredCredential(.intervalsConnection)))
		let events = coach.diagnostics.entries.map(\.event)
		#expect(!events.isEmpty)
		#expect(
			events.allSatisfy {
				$0
					== .secureStorageFailed(
						.intervalsConnection, failure: KeychainStoreError.keychain(errSecDecode))
			})
		#expect(memory.writes(to: "intervalsCredential") == 2)
	}

	@Test func credentialsRetryAfterUnlock() async throws {
		let backing = FixtureSecretStoreBacking()
		let secrets = keyedSecrets(backing: backing)
		backing.locked = true
		let coach = await coach(secrets)
		#expect(
			try await coach.refreshedStatus().setup
				== .accessTemporarilyUnavailable(.secureStorageLocked))
		backing.locked = false
		await coach.lifecycle(.becameActive)
		#expect(try await coach.refreshedStatus().needsProviderConsent)
		try await coach.recordConsent()
		#expect(try await coach.refreshedStatus().setup == .ready)
	}

	@Test func concurrentReplacementThenDisconnectKeepsDisconnect() async throws {
		let secrets = keyedSecrets()
		let delayed = FakeIntervalsClient(
			athlete: .cyclist(id: "i1001", name: "Ada Kovač", ftp: 250))
		let gate = delayed.hold(.profile)
		let service = TrainingService { credential, _ in
			if credential == .apiKey("test-delayed-key") { return delayed }
			return self.ada
		}
		let coach = await coach(secrets, training: service)
		let replacement = Task {
			await coach.changeTraining(.replace(apiKey: "test-delayed-key", athlete: .keyOwner))
		}
		try #require(
			try await beforeDeadline(within: .hangGuard, onTimeout: { replacement.cancel() }) {
				await gate.waitUntilEntered()
			} != nil)
		let disconnect = Task { await coach.changeTraining(.disconnect) }
		try await Task.sleep(for: .milliseconds(150))
		await gate.release()
		_ = await replacement.value
		#expect(await disconnect.value == .disconnected)
		#expect(try secrets.intervalsConnection() == nil)
		#expect(try await coach.refreshedStatus().training == .unconnected)
		#expect(try await claimAccount(after: "Is Thursday on?", on: coach) == .unconnected)
	}

	@Test func oldProfileReadDoesNotOverwriteReplacement() async throws {
		let secrets = keyedSecrets()
		try secrets.storeIntervalsConnection(
			IntervalsConnection(
				id: testConnection.id, credential: .apiKey("test-unresolved"),
				selection: .keyOwner, resolvedAthlete: nil))
		let ada = self.ada
		let gate = ada.hold(.profile)
		let service = TrainingService { credential, _ in
			if credential == .apiKey("test-unresolved") { return ada }
			return self.bo
		}
		let coach = await coach(secrets, training: service)
		let status = Task { try await coach.refreshedStatus() }
		try #require(
			try await beforeDeadline(within: .hangGuard, onTimeout: { status.cancel() }) {
				await gate.waitUntilEntered()
			} != nil)
		_ = await coach.changeTraining(.replace(apiKey: "other-athlete", athlete: .keyOwner))
		let replacement = try #require(try secrets.intervalsConnection())
		await gate.release()
		_ = try await status.value
		#expect(try secrets.intervalsConnection() == replacement)
		#expect(try await claimAccount(after: "Is Thursday on?", on: coach) == account(replacement))
	}
}
