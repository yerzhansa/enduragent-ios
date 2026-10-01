import EnduragentCoachFixtures
import Foundation
import Synchronization
import Testing

@testable import EnduragentCoach

extension CreditsClientTests {
	@Test func accountDeletedDuringGrantWritesNothing() async throws {
		let memory = FixtureSecretStoreBacking()
		let device = ICloudKeychainStore(backing: memory)
		let client = try makeClient(secrets: device)
		let peer = ICloudKeychainStore(backing: memory)
		await #expect(throws: CreditsFailure.accountChanged) {
			try await CreditsURLStub.withHandler({ _ in
				do {
					try peer.delete(.creditsAccount)
				} catch {
					Issue.record(error)
				}
				return .json(200, #"{"kind":"grantMinted","key":"test-granted-key","credits":200}"#)
			}) {
				_ = try await client.grant(deviceCheck: Data([0x01]))
			}
		}
		#expect(try device.creditsAccount() == nil)
		#expect(memory.writes(to: "creditsAccount") == 1)
	}

	@Test func reviewGrantDuringPeerRecoveryKeepsAWholePair() async throws {
		try await mintedKeyDuringPeerRecovery(isClaim: false, recoveredBeforeRequest: false)
	}

	@Test(arguments: [false, true])
	func claimDuringPeerRecoveryKeepsAWholePair(recoveredBeforeRequest: Bool) async throws {
		try await mintedKeyDuringPeerRecovery(
			isClaim: true, recoveredBeforeRequest: recoveredBeforeRequest)
	}

	private func mintedKeyDuringPeerRecovery(
		isClaim: Bool, recoveredBeforeRequest: Bool
	) async throws {
		let oldToken = try #require(UUID(uuidString: "11111111-2222-4333-8444-555555555555"))
		let newToken = try #require(UUID(uuidString: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"))
		let memory = FixtureSecretStoreBacking()
		let device = ICloudKeychainStore(backing: memory)
		try device.storeCreditsAccount(CreditsAccount(appAccountToken: oldToken, key: nil))
		let client = try makeClient(secrets: device)
		let peer = ICloudKeychainStore(backing: memory)
		let recovered = CreditsAccount(appAccountToken: newToken, key: "test-recovered-key")
		if recoveredBeforeRequest { try peer.storeCreditsAccount(recovered) }
		let captured = Mutex<String?>(nil)
		await #expect(throws: CreditsFailure.accountChanged) {
			try await CreditsURLStub.withHandler({ request in
				captured.withLock { $0 = request.url?.path }
				do {
					if !recoveredBeforeRequest { try peer.storeCreditsAccount(recovered) }
				} catch {
					Issue.record(error)
				}
				return isClaim
					? .json(
						200, #"{"kind":"claimMinted","key":"test-claimed-key","creditsAdded":500}"#)
					: .json(200, #"{"kind":"grantMinted","key":"test-granted-key","credits":200}"#)
			}) {
				if isClaim {
					_ = try await client.claim(
						signedTransaction: "header.payload.signature", appAccountToken: oldToken)
				} else {
					_ = try await client.grant(deviceCheck: Data([0x01]))
				}
			}
		}
		#expect(captured.withLock { $0 } == (isClaim ? "/claim" : "/grant"))
		#expect(try device.creditsAccount() == recovered)
		#expect(try peer.creditsAccount() == recovered)
		#expect(memory.writes(to: "creditsAccount") == 2)
	}

	@Test func grantMintsTheTokenOnce() async throws {
		let memory = FixtureSecretStoreBacking()
		let store = ICloudKeychainStore(backing: memory)
		let client = try makeClient(secrets: store)
		let sentTokens = Mutex<[String]>([])
		try await CreditsURLStub.withHandler({ request in
			do {
				let body = try jsonObject(from: request)
				let token = try #require(body["athleteId"] as? String)
				sentTokens.withLock { $0.append(token) }
			} catch {
				Issue.record(error)
			}
			return .json(200, #"{"kind":"grantAlreadyGranted"}"#)
		}) {
			_ = try await client.grant(deviceCheck: Data([0x01]))
			let first = try #require(try store.creditsAccount())
			_ = try await client.grant(deviceCheck: Data([0x01]))
			#expect(try store.creditsAccount() == first)
			#expect(
				sentTokens.withLock { $0 }
					== Array(repeating: first.appAccountToken.uuidString.lowercased(), count: 2))
		}
		#expect(memory.writes(to: "creditsAccount") == 1)
		#expect(memory.writes(to: "appAccountToken") == 0)
	}
}

extension CredentialVaultTests {
	@Test func replyWithNoAccountWritesNothing() async throws {
		let memory = FixtureSecretStoreBacking()
		let coach = await coach(ICloudKeychainStore(backing: memory))
		let settled = try await coach.sendAndSettle("Is Thursday on?")
		#expect(failure(settled) == .model(.accessUnavailable(.notConfigured(.credits))))
		#expect(memory.writeCount == 0)
		#expect(memory.deletedAccounts.isEmpty)
		#expect(transport.requests.isEmpty)
	}

	@Test func statusWithNoAccountWritesNothing() async throws {
		let memory = FixtureSecretStoreBacking()
		let store = ICloudKeychainStore(backing: memory)
		let coach = await coach(store)
		#expect(await coach.status().setup == .needsAccessMethod)
		#expect(try await coach.creditsIdentity().hasCreditsKey == false)
		#expect(try await vault(store).creditsKey() == nil)
		#expect(memory.writeCount == 0)
		#expect(memory.deletedAccounts.isEmpty)
	}
}
