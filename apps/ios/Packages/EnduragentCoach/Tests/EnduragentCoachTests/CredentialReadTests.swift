import Foundation
import Security
import Testing

@testable import EnduragentCoach

extension CredentialVaultTests {
	@Test func lockedStoreReportsSecureStorageLocked() async throws {
		let secrets = keyedSecrets()
		secrets.locked = true
		await #expect(throws: AccessUnavailable.secureStorageLocked) {
			try await vault(secrets).modelAccess(builtInModel: testModel)
		}
		let status = await coach(secrets).status()
		#expect(status.setup == .accessTemporarilyUnavailable(.secureStorageLocked))
		#expect(status.training == .unavailable(.secureStorageLocked))
		#expect(status.notice?.key == Catalog.accessErrorLocked)
		#expect(status.notice?.action == nil)

		let memory = MemorySecretStoreBacking()
		memory.fail(CredentialSlot.accessSelection.rawValue, with: errSecInteractionNotAllowed)
		await #expect(throws: AccessUnavailable.secureStorageLocked) {
			try await vault(ICloudKeychainStore(backing: memory)).modelAccess(
				builtInModel: testModel)
		}
	}

	@Test func malformedItemReportsSlotWithoutContent() async throws {
		let memory = MemorySecretStoreBacking(items: [
			CredentialSlot.creditsKey.rawValue: Data([0xFF, 0xFE, 0xFD]),
			CredentialSlot.intervalsConnection.rawValue: Data(
				#"{"credential":"sk-or-v0-leaked-content"}"#.utf8),
		])
		let diagnostics = DiagnosticsLog(clock: clock)
		let vault = CredentialVault(
			store: ICloudKeychainStore(backing: memory), training: training, clock: clock,
			diagnostics: diagnostics)
		await #expect(throws: AccessUnavailable.malformedStoredCredential(.creditsKey)) {
			try await vault.modelAccess(builtInModel: testModel)
		}
		do {
			_ = try await vault.trainingConnection()
			Issue.record("expected a malformed intervals item")
		} catch {
			#expect(error == .malformedStoredCredential(.intervalsConnection))
			#expect(!String(describing: error).contains("leaked"))
		}
		#expect(diagnostics.entries.isEmpty)
	}

	@Test func malformedKeyFailsTheTurnAndTheFailureSurvivesRelaunch() async throws {
		let memory = MemorySecretStoreBacking(items: [
			CredentialSlot.creditsKey.rawValue: Data([0xFF, 0xFE, 0xFD])
		])
		let keychain = ICloudKeychainStore(backing: memory)
		let settled = try await coach(keychain).sendAndSettle("Is Thursday on?")
		guard case .failed(let failed) = settled else {
			Issue.record("expected a failed turn, got \(settled)")
			return
		}
		#expect(failed.notice.key == Catalog.accessErrorNotConfigured)
		let reopened = try #require(await coach(keychain).currentSnapshot(.main))
		#expect(reopened.turns.map(\.state) == [settled])
		#expect(transport.requests.isEmpty)
	}

	@Test func resolverReadsOnlyTheSelectedMethodKey() async throws {
		let secrets = FakeSecretStore()
		try secrets.storeOpenRouterKey("sk-or-credits")
		try secrets.storeOpenRouterAccountKey("sk-or-account")
		let model = ModelID(rawValue: "test/account-model")
		try secrets.storeAccessSelection(
			.openRouterAccount(
				model: model,
				consent: ProviderConsent(provider: "Test Provider", model: model, at: clock.now)))
		let vault = vault(secrets)
		#expect(
			try await vault.modelAccess(builtInModel: testModel)
				== ResolvedAccess(
					credential: ProviderCredential(
						secret: "sk-or-account", method: .openRouterAccount),
					model: model))
		#expect(
			secrets.reads == [.intervalsConnectionStaging, .accessSelection, .openRouterAccountKey])
		try secrets.delete(.openRouterAccountKey)
		await #expect(throws: AccessUnavailable.notConfigured(.openRouterAccount)) {
			try await vault.modelAccess(builtInModel: testModel)
		}
		#expect(!secrets.reads.contains(.creditsKey))
		try secrets.storeAccessSelection(.credits)
		#expect(
			try await vault.modelAccess(builtInModel: testModel)
				== testAccess(secret: "sk-or-credits"))
		#expect(secrets.reads.suffix(2) == [.accessSelection, .creditsKey])
		#expect(secrets.reads.filter { $0 == .openRouterAccountKey }.count == 2)
	}

	@Test func recoverStagingDeletesLeftoverAtLaunch() async throws {
		let secrets = keyedSecrets()
		try secrets.stageReplacement(
			.intervals(
				IntervalsConnection(
					id: ConnectionID(), credential: .apiKey("icu-half-written"),
					selection: .keyOwner,
					resolvedAthlete: nil)))
		let launched = try await vault(secrets).trainingConnection()
		#expect(try secrets.stagedReplacement() == nil)
		#expect(launched.account == (try account(testConnection)))
	}

	@Test func v1ConnectionResolvesItsAthleteOnTheFirstRead() async throws {
		let memory = MemorySecretStoreBacking(items: [
			CredentialSlot.creditsKey.rawValue: Data(testKey.utf8),
			CredentialSlot.intervalsConnection.rawValue: Data(
				#"{"apiKey":{"_0":"icu-v1-key"}}"#.utf8),
		])
		let keychain = ICloudKeychainStore(backing: memory)
		let coach = coach(keychain)
		_ = await coach.status()
		let resolved = try #require(try keychain.intervalsConnection())
		#expect(resolved.id != nil)
		#expect(resolved.resolvedAthlete?.rawValue == "i1001")
		_ = await coach.status()
		#expect(try keychain.intervalsConnection() == resolved)
		#expect(memory.writes(to: CredentialSlot.intervalsConnection.rawValue) == 2)
	}

	@Test func athleteSelectionReachesEveryTrainingClient() async throws {
		let secrets = keyedSecrets()
		let coach = coach(secrets)
		let coached = try #require(IntervalsAthleteID(rawValue: "i2002"))
		guard
			case .replaced = await coach.changeTraining(
				.replace(apiKey: "icu-coach-key", athlete: .athlete(coached)))
		else {
			Issue.record("expected the coach key to be stored")
			return
		}
		#expect(try secrets.intervalsConnection()?.selection == .athlete(coached))
		_ = try await claimAccount(after: "How is my athlete doing?", on: coach)
		#expect(built.athletes == [.athlete(coached), .athlete(coached)])
	}

	@Test func perAttemptResolutionStaysUnderFiftyMilliseconds() async throws {
		let backing = MemorySecretStoreBacking()
		let keychain = ICloudKeychainStore(backing: backing)
		try keychain.storeOpenRouterKey(testKey)
		try keychain.storeIntervalsConnection(testConnection)
		let vault = vault(keychain)
		let expectedAccount = try account(testConnection)
		var samples = PerformanceSamples()
		var expectedReads = 7
		for _ in 0..<PerformanceSamples.batchCount {
			try await samples.measure(count: 200) {
				let before = backing.readCount
				let access = try await vault.modelAccess(builtInModel: testModel)
				let connection = try await vault.trainingConnection()
				return (access, connection, backing.readCount - before)
			} validate: { access, connection, reads in
				#expect(reads == expectedReads)
				expectedReads = 6
				#expect(access == testAccess(secret: testKey))
				#expect(connection.account == expectedAccount)
			}
		}
		try samples.check(budget: .milliseconds(50), name: "credential-median")
		try samples.check(
			budget: .milliseconds(50), quantile: .p95, across: .allAttempts, name: "credential-p95")
	}
}
