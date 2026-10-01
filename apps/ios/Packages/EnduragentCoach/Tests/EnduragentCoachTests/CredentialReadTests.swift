import Foundation
import Security
import Testing

@testable import EnduragentCoach

extension CredentialVaultTests {
	@Test func replyMakesThreeKeychainReads() async throws {
		let memory = FixtureSecretStoreBacking()
		let store = ICloudKeychainStore(backing: memory)
		try store.storeCreditsAccount(CreditsAccount(appAccountToken: UUID(), key: testKey))
		try store.storeIntervalsConnection(testConnection)
		let coach = coach(store)
		let before = memory.readCount
		transport.script = [.text("Thursday is on."), .finish(reason: .stop)]
		#expect(replyText(try await coach.sendAndSettle("Is Thursday on?")) == "Thursday is on.")
		#expect(memory.readCount - before == 3)
		#expect(
			Array(memory.readAccounts.dropFirst(before)) == [
				"accessSelection", "creditsAccount", "intervalsCredential",
			])
		#expect(transport.requests.last?.credential.secret == testKey)
	}

	@Test func lockedKeychainLogsNoDiagnostics() async throws {
		let memory = FixtureSecretStoreBacking()
		for account in [
			"accessSelection", "creditsAccount", "intervalsCredential", "openRouterAccountKey",
			"openRouterKey", "appAccountToken",
		] {
			memory.fail(account, with: errSecInteractionNotAllowed)
		}
		let coach = coach(ICloudKeychainStore(backing: memory))
		let settled = try await coach.sendAndSettle("Is Thursday on?")
		#expect(failure(settled) == .model(.accessUnavailable(.secureStorageLocked)))
		#expect(coach.diagnostics.entries.isEmpty)
		let status = await coach.status()
		#expect(status.setup == .accessTemporarilyUnavailable(.secureStorageLocked))
		#expect(status.training == .unavailable(.secureStorageLocked))
		#expect(coach.diagnostics.entries.isEmpty)
		#expect(transport.requests.isEmpty)
	}

	@Test func lockedStoreReportsSecureStorageLocked() async throws {
		let backing = FixtureSecretStoreBacking()
		let secrets = keyedSecrets(backing: backing)
		backing.locked = true
		await #expect(throws: AccessUnavailable.secureStorageLocked) {
			try await vault(secrets).modelAccess(builtInModel: testModel)
		}
		let status = await coach(secrets).status()
		#expect(status.setup == .accessTemporarilyUnavailable(.secureStorageLocked))
		#expect(status.training == .unavailable(.secureStorageLocked))
		#expect(status.notice?.key == Catalog.accessErrorLocked)
		#expect(status.notice?.action == nil)

		let memory = FixtureSecretStoreBacking()
		memory.fail(CredentialSlot.accessSelection.rawValue, with: errSecInteractionNotAllowed)
		await #expect(throws: AccessUnavailable.secureStorageLocked) {
			try await vault(ICloudKeychainStore(backing: memory)).modelAccess(
				builtInModel: testModel)
		}
	}

	@Test func malformedItemReportsSlotWithoutContent() async throws {
		let memory = FixtureSecretStoreBacking(items: [
			CredentialSlot.creditsAccount.rawValue: Data([0xFF, 0xFE, 0xFD]),
			CredentialSlot.intervalsConnection.rawValue: Data(
				#"{"credential":"sk-or-v0-leaked-content"}"#.utf8),
		])
		let diagnostics = DiagnosticsLog(clock: clock)
		let vault = CredentialVault(
			store: ICloudKeychainStore(backing: memory), training: training, clock: clock,
			diagnostics: diagnostics)
		await #expect(throws: AccessUnavailable.malformedStoredCredential(.creditsAccount)) {
			try await vault.modelAccess(builtInModel: testModel)
		}
		do {
			_ = try await vault.trainingConnection()
			Issue.record("expected a malformed intervals item")
		} catch {
			#expect(error == .malformedStoredCredential(.intervalsConnection))
			#expect(!String(describing: error).contains("leaked"))
		}
		#expect(
			diagnostics.entries.map(\.event) == [
				.secureStorageFailed(
					.creditsAccount, failure: KeychainStoreError.keychain(errSecDecode)),
				.secureStorageFailed(
					.intervalsConnection, failure: KeychainStoreError.keychain(errSecDecode)),
			])
	}

	@Test func malformedKeyFailsTheTurnAndTheFailureSurvivesRelaunch() async throws {
		let memory = FixtureSecretStoreBacking(items: [
			CredentialSlot.creditsAccount.rawValue: Data([0xFF, 0xFE, 0xFD])
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
		let backing = FixtureSecretStoreBacking()
		let secrets = ICloudKeychainStore(backing: backing)
		try secrets.storeCreditsAccount(
			CreditsAccount(appAccountToken: UUID(), key: "sk-or-credits"))
		try secrets.storeOpenRouterAccountKey("sk-or-account")
		let model = ModelID(rawValue: "test/account-model")
		try secrets.storeAccessSelection(
			.openRouterAccount(
				model: model,
				consent: ProviderConsent(provider: "Test Provider", model: model, at: clock.now)))
		let readsBeforeResolving = backing.readCount
		let vault = vault(secrets)
		#expect(
			try await vault.modelAccess(builtInModel: testModel)
				== ResolvedAccess(
					credential: ProviderCredential(
						secret: "sk-or-account", method: .openRouterAccount),
					model: model))
		#expect(
			backing.readAccounts.dropFirst(readsBeforeResolving) == [
				CredentialSlot.accessSelection.rawValue,
				CredentialSlot.openRouterAccountKey.rawValue,
			])
		try secrets.delete(.openRouterAccountKey)
		await #expect(throws: AccessUnavailable.notConfigured(.openRouterAccount)) {
			try await vault.modelAccess(builtInModel: testModel)
		}
		#expect(
			!backing.readAccounts.dropFirst(readsBeforeResolving).contains(
				CredentialSlot.creditsAccount.rawValue))
		try secrets.storeAccessSelection(.credits)
		#expect(
			try await vault.modelAccess(builtInModel: testModel)
				== testAccess(secret: "sk-or-credits"))
		#expect(
			backing.readAccounts.dropFirst(readsBeforeResolving).suffix(2) == [
				CredentialSlot.accessSelection.rawValue, CredentialSlot.creditsAccount.rawValue,
			])
		#expect(
			backing.readAccounts.dropFirst(readsBeforeResolving).filter {
				$0 == CredentialSlot.openRouterAccountKey.rawValue
			}.count == 2)
	}

	@Test func v1ConnectionResolvesItsAthleteOnTheFirstRead() async throws {
		let memory = FixtureSecretStoreBacking(items: [
			"openRouterKey": Data(testKey.utf8),
			CredentialSlot.intervalsConnection.rawValue: Data(
				#"{"apiKey":{"_0":"icu-v1-key"}}"#.utf8),
		])
		let keychain = ICloudKeychainStore(backing: memory)
		let coach = coach(keychain)
		_ = await coach.status()
		let resolved = try #require(try keychain.intervalsConnection())
		#expect(resolved.resolvedAthlete?.rawValue == "i1001")
		_ = await coach.status()
		#expect(try keychain.intervalsConnection() == resolved)
		#expect(memory.writes(to: CredentialSlot.intervalsConnection.rawValue) == 1)
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

	@Test func perAttemptResolutionReadsThreeCredentialSlots() async throws {
		let backing = FixtureSecretStoreBacking()
		let keychain = ICloudKeychainStore(backing: backing)
		try keychain.storeCreditsAccount(
			CreditsAccount(appAccountToken: UUID(), key: testKey)
		)
		try keychain.storeIntervalsConnection(testConnection)
		let vault = vault(keychain)
		let expectedAccount = account(testConnection)
		let before = backing.readCount
		let access = try await vault.modelAccess(builtInModel: testModel)
		let connection = try await vault.trainingConnection()
		#expect(backing.readCount - before == 3)
		#expect(access == testAccess(secret: testKey))
		#expect(connection.account == expectedAccount)
	}
}
