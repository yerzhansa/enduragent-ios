import EnduragentCoachFixtures
import Foundation
import Security
import Testing

@testable import EnduragentCoach

@Suite struct CredentialRecoveryTests {
	@Test func blockedMigrationPreservesLegacyItemsAndRetriesAfterUnlock() async throws {
		let oldToken = try #require(UUID(uuidString: "11111111-2222-4333-8444-555555555555"))
		let previous = CreditsAccount(appAccountToken: oldToken, key: "test-old-credits-key")
		let memory = legacyCreditsBacking(previous)
		memory.failWrites(CredentialSlot.creditsAccount.rawValue, with: errSecInteractionNotAllowed)
		let store = ICloudKeychainStore(backing: memory)
		let coach = makeCoach(
			transport: FakeModelTransport(), store: InMemoryRecordLog(), secrets: store)

		await #expect(throws: AccessUnavailable.secureStorageLocked) {
			try await coach.creditsIdentity()
		}
		#expect(try memory.copy(account: "openRouterKey") == Data("test-old-credits-key".utf8))
		#expect(try memory.copy(account: CredentialSlot.creditsAccount.rawValue) == nil)
		#expect(coach.diagnostics.entries.isEmpty)

		memory.failWrites(CredentialSlot.creditsAccount.rawValue, with: nil)
		#expect(
			try await coach.creditsIdentity()
				== CreditsIdentity(appAccountToken: oldToken, hasCreditsKey: true))
		#expect(try store.creditsAccount() == previous)
		#expect(try memory.copy(account: "openRouterKey") == nil)
	}
}

extension CreditsClientTests {
	@Test(arguments: 0...4)
	func crashDuringRecoveryThenPeerIntervalsReplaceLeavesAWholePair(_ writes: Int) async throws {
		let oldToken = try #require(UUID(uuidString: "11111111-2222-4333-8444-555555555555"))
		let newToken = try #require(UUID(uuidString: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"))
		let oldKey = "test-old-credits-key"
		let newKey = "test-new-credits-key"
		let memory = FixtureSecretStoreBacking()
		let deviceB = ICloudKeychainStore(backing: memory)
		try deviceB.storeCreditsAccount(CreditsAccount(appAccountToken: oldToken, key: oldKey))
		try deviceB.storeIntervalsConnection(testConnection)
		let coachB = makeCoach(
			transport: FakeModelTransport(), store: InMemoryRecordLog(), secrets: deviceB)
		#expect(await coachB.status().setup == .ready)
		let interrupted = InterruptedSecretStoreBacking(base: memory)
		let deviceA = ICloudKeychainStore(backing: interrupted)
		let client = try makeClient(secrets: deviceA)
		_ = try await CreditsURLStub.withHandler({ _ in
			.json(200, #"{"data":{"limit_remaining":1}}"#)
		}) {
			try await client.balance(scale: CreditScale(creditsPerUsd: 100))
		}
		interrupted.stop(after: writes)
		do {
			_ = try await CreditsURLStub.withHandler({ _ in
				.json(
					200,
					#"{"kind":"recovered","athleteId":"aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee","key":"test-new-credits-key","credits":150}"#
				)
			}) {
				try await client.recover(signedTransaction: "header.payload.signature")
			}
		} catch let error as AccessUnavailable {
			#expect(error == .secureStorageUnavailable)
		}
		guard
			case .replaced = await coachB.changeTraining(
				.replace(apiKey: "icu-rotated-key", athlete: .keyOwner))
		else {
			Issue.record("expected the peer intervals replacement to succeed")
			return
		}
		interrupted.resume()
		let coachA = makeCoach(
			transport: FakeModelTransport(), store: InMemoryRecordLog(), secrets: deviceA)
		for (coach, store) in [(coachA, deviceA), (coachB, deviceB)] {
			let identity = try await coach.creditsIdentity()
			let key = try store.creditsAccount()?.key
			#expect(identity.hasCreditsKey)
			#expect(
				(key == oldKey && identity.appAccountToken == oldToken)
					|| (key == newKey && identity.appAccountToken == newToken),
				"after \(writes) writes: key=\(key ?? "nil"), token=\(identity.appAccountToken)")
		}
	}

	@Test func successfulRecoveryCommitsBothValues() async throws {
		let oldToken = try #require(UUID(uuidString: "11111111-2222-4333-8444-555555555555"))
		let newToken = try #require(UUID(uuidString: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"))
		let memory = FixtureSecretStoreBacking()
		let original = ICloudKeychainStore(backing: memory)
		try original.storeCreditsAccount(
			CreditsAccount(appAccountToken: oldToken, key: "test-old-credits-key"))
		let client = try makeClient(secrets: original)

		_ = try await CreditsURLStub.withHandler({ _ in
			.json(
				200,
				#"{"kind":"recovered","athleteId":"aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee","key":"test-new-credits-key","credits":150}"#
			)
		}) {
			try await client.recover(signedTransaction: "test.signed.transaction")
		}

		let restarted = ICloudKeychainStore(backing: memory)
		let coach = makeCoach(
			transport: FakeModelTransport(), store: InMemoryRecordLog(), secrets: restarted)
		#expect(
			try await coach.creditsIdentity()
				== CreditsIdentity(appAccountToken: newToken, hasCreditsKey: true))
		#expect(
			try restarted.creditsAccount()
				== CreditsAccount(appAccountToken: newToken, key: "test-new-credits-key"))
	}
}

func legacyCreditsBacking(_ account: CreditsAccount) -> FixtureSecretStoreBacking {
	var items = ["appAccountToken": Data(account.appAccountToken.uuidString.utf8)]
	items["openRouterKey"] = account.key.map { Data($0.utf8) }
	return FixtureSecretStoreBacking(items: items)
}
