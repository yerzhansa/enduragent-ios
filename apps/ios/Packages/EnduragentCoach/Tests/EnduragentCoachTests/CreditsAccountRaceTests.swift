import Foundation
import Synchronization
import Testing

@testable import EnduragentCoach

extension CreditsClientTests {
	@Test func reviewGrantDuringPeerRecoveryKeepsAWholePair() async throws {
		try await mintedKeyDuringPeerRecovery(isClaim: false)
	}

	@Test func claimDuringPeerRecoveryKeepsAWholePair() async throws {
		try await mintedKeyDuringPeerRecovery(isClaim: true)
	}

	private func mintedKeyDuringPeerRecovery(isClaim: Bool) async throws {
		let oldToken = try #require(UUID(uuidString: "11111111-2222-4333-8444-555555555555"))
		let newToken = try #require(UUID(uuidString: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"))
		let memory = MemorySecretStoreBacking()
		let device = ICloudKeychainStore(backing: memory)
		try device.storeCreditsAccount(CreditsAccount(appAccountToken: oldToken, key: nil))
		let client = try makeClient(secrets: device)
		let peer = ICloudKeychainStore(backing: memory)
		let recovered = CreditsAccount(appAccountToken: newToken, key: "test-recovered-key")
		let captured = Mutex<String?>(nil)
		await #expect(throws: (any Error).self) {
			try await CreditsURLStub.withHandler({ request in
				captured.withLock { $0 = request.url?.path }
				do {
					try peer.storeCreditsAccount(recovered)
				} catch {
					Issue.record(error)
				}
				return isClaim
					? .json(
						200, #"{"kind":"claimMinted","key":"test-claimed-key","creditsAdded":500}"#)
					: .json(200, #"{"kind":"grantMinted","key":"test-granted-key","credits":200}"#)
			}) {
				if isClaim {
					_ = try await client.claim(signedTransaction: "header.payload.signature")
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
		let memory = MemorySecretStoreBacking()
		let store = ICloudKeychainStore(backing: memory)
		let client = try makeClient(secrets: store)
		try await CreditsURLStub.withHandler({ _ in
			.json(200, #"{"kind":"grantAlreadyGranted"}"#)
		}) {
			_ = try await client.grant(deviceCheck: Data([0x01]))
			let first = try store.creditsAccount()
			_ = try await client.grant(deviceCheck: Data([0x01]))
			#expect(try store.creditsAccount() == first)
		}
		#expect(memory.writes(to: "creditsAccount") == 1)
		#expect(memory.writes(to: "appAccountToken") == 0)
	}
}

extension CredentialVaultTests {
	@Test func replyWithNoAccountWritesNothing() async throws {
		let memory = MemorySecretStoreBacking()
		let coach = coach(ICloudKeychainStore(backing: memory))
		let settled = try await coach.sendAndSettle("Is Thursday on?")
		#expect(failure(settled) == .model(.accessUnavailable(.notConfigured(.credits))))
		#expect(memory.writes(to: "creditsAccount") == 0)
		#expect(memory.deletedAccounts.isEmpty)
		#expect(transport.requests.isEmpty)
	}

	@Test func statusWithNoAccountWritesNothing() async throws {
		let memory = MemorySecretStoreBacking()
		let store = ICloudKeychainStore(backing: memory)
		let coach = coach(store)
		#expect(await coach.status().setup == .needsAccessMethod)
		#expect(try await coach.creditsIdentity().hasCreditsKey == false)
		#expect(try await vault(store).creditsKey() == nil)
		#expect(memory.writes(to: "creditsAccount") == 0)
		#expect(memory.deletedAccounts.isEmpty)
	}
}
