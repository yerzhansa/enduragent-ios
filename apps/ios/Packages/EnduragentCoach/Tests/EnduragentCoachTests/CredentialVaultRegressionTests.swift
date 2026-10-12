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
		let gate = Gate()
		let client = GatedProfileIntervals(base: ada, gate: gate)
		let coach = await coach(
			secrets, training: TrainingService { _, _, _ in client })
		let status = Task { try await coach.refreshedStatus() }
		defer {
			status.cancel()
			gate.release()
		}
		try #require(
			try await beforeDeadline(
				within: .hangGuard,
				onTimeout: {
					status.cancel()
					gate.release()
				}
			) { await gate.waitUntilParked() } != nil)
		if failingWrite {
			memory.failWrites("intervalsCredential", with: statusCode)
		} else {
			memory.fail("intervalsCredential", with: statusCode)
		}
		gate.release()
		let resolved = try #require(
			try await beforeDeadline(
				within: .hangGuard,
				onTimeout: {
					status.cancel()
					gate.release()
				}
			) { try await status.value })
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
		let gate = Gate()
		let client = GatedProfileIntervals(base: ada, gate: gate)
		let coach = await coach(
			secrets, training: TrainingService { _, _, _ in client })
		let status = Task { try await coach.refreshedStatus() }
		await gate.waitUntilParked()
		try memory.update(account: "intervalsCredential", data: Data([0xFF, 0xFE, 0xFD]))
		gate.release()
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

	@Test func oldProposalCannotExecuteForTheNewAthlete() async throws {
		let secrets = keyedSecrets()
		let coach = await coach(secrets)
		let pending = try await proposeRide(on: coach)
		#expect(await coach.decide(.presented(pending.ref), in: .main) == .presentationRecorded)
		let token = try #require(await coach.currentSnapshot(.main)?.review?.token)
		_ = try await coach.refreshedStatus()
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
		let coach = await coach(secrets)
		let pending = try await proposeRide(on: coach)
		#expect(await coach.decide(.presented(pending.ref), in: .main) == .presentationRecorded)
		let token = try #require(await coach.currentSnapshot(.main)?.review?.token)
		let original = try #require(try secrets.intervalsConnection())
		_ = await coach.changeTraining(.replace(apiKey: "same-athlete-new-key", athlete: .keyOwner))
		let current = try #require(try secrets.intervalsConnection())
		#expect(current.resolvedAthlete == testConnection.resolvedAthlete)
		#expect(current.id != testConnection.id)
		#expect(account(original).authority(under: account(current)) == .sameAthlete)
		try await expectStillApproved(token, on: coach)
	}

	@Test func resolvingTheSameConnectionPreservesProposal() async throws {
		let secrets = keyedSecrets()
		try secrets.storeIntervalsConnection(
			IntervalsConnection(
				id: testConnection.id, credential: testConnection.credential,
				selection: .keyOwner, resolvedAthlete: nil))
		let coach = await coach(secrets)
		let pending = try await proposeRide(on: coach)
		#expect(await coach.decide(.presented(pending.ref), in: .main) == .presentationRecorded)
		let token = try #require(await coach.currentSnapshot(.main)?.review?.token)
		let original = try #require(try secrets.intervalsConnection())
		_ = try await coach.refreshedStatus()
		let current = try #require(try secrets.intervalsConnection())
		#expect(current.id == testConnection.id)
		#expect(current.resolvedAthlete != nil)
		#expect(account(original).authority(under: account(current)) == .same)
		try await expectStillApproved(token, on: coach)
	}

	private func expectStillApproved(_ token: ReviewControlToken, on coach: Coach) async throws {
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
		_ = try await proposeRide(on: coach(secrets))
		let saved = try await records.fetch(RecordQuery(scope: .everyDeviceLocal))
		let restored = InMemoryRecordLog(deviceId: records.deviceId)
		let original = TrainingAccount.intervals(connection: testConnection.id, athlete: nil)
		try await restored.append(
			saved.records.map {
				AthleteRecord(
					ulid: $0.ulid, deviceId: $0.deviceId, hlc: $0.hlc, timeZone: $0.timeZone,
					civilDate: $0.civilDate, cause: $0.cause, account: original, body: $0.body)
			}, locality: .deviceLocal)
		let coach = await coach(secrets, log: restored)
		let pending = try #require(await coach.currentSnapshot(.main)?.review)
		#expect(await coach.decide(.presented(pending.ref), in: .main) == .presentationRecorded)
		let token = try #require(await coach.currentSnapshot(.main)?.review?.token)
		_ = await coach.changeTraining(
			.replaceConfirmingAthleteSwitch(apiKey: "same-athlete-new-key", athlete: .keyOwner))
		let current = try #require(try secrets.intervalsConnection())
		#expect(current.id != testConnection.id)
		#expect(current.resolvedAthlete == testConnection.resolvedAthlete)
		#expect(original.authority(under: account(current)) == .unverifiable)
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
		let gate = Gate()
		let client = GatedProfileIntervals(base: ada, gate: gate)
		let service = TrainingService { credential, _, _ in
			if credential == .apiKey("test-delayed-key") { return client }
			return self.ada
		}
		let coach = await coach(secrets, training: service)
		let replacement = Task {
			await coach.changeTraining(.replace(apiKey: "test-delayed-key", athlete: .keyOwner))
		}
		await gate.waitUntilParked()
		let disconnect = Task { await coach.changeTraining(.disconnect) }
		try await Task.sleep(for: .milliseconds(150))
		gate.release()
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
		let gate = Gate()
		let old = GatedProfileIntervals(base: ada, gate: gate)
		let service = TrainingService { credential, _, _ in
			if credential == .apiKey("test-unresolved") { return old }
			return self.bo
		}
		let coach = await coach(secrets, training: service)
		let status = Task { try await coach.refreshedStatus() }
		await gate.waitUntilParked()
		_ = await coach.changeTraining(.replace(apiKey: "other-athlete", athlete: .keyOwner))
		let replacement = try #require(try secrets.intervalsConnection())
		gate.release()
		_ = try await status.value
		#expect(try secrets.intervalsConnection() == replacement)
		#expect(try await claimAccount(after: "Is Thursday on?", on: coach) == account(replacement))
	}
}
