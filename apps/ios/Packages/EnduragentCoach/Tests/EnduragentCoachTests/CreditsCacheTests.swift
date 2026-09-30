import Foundation
import Testing

@testable import EnduragentCoach

extension CreditsClientTests {
	@Test func balanceIsNotServedFromCache() async throws {
		let server = try CacheableHTTPServer { count in
			"{\"data\":{\"limit_remaining\":\(count == 1 ? 2 : 1)}}"
		}
		defer { server.stop() }
		let base = try await server.start()
		let secrets = ICloudKeychainStore(backing: FixtureSecretStoreBacking())
		try secrets.storeCreditsAccount(
			CreditsAccount(appAccountToken: UUID(), key: "sk-or-test-cache"))
		let client = PhoneCreditsClient(
			vault: testVault(secrets), workerBase: base, openRouterBase: base)
		let scale = CreditScale(creditsPerUsd: 100)
		let first = try await client.balance(scale: scale)
		let second = try await client.balance(scale: scale)
		#expect(first == CreditBalance(credits: Credits(units: 200)))
		#expect(second == CreditBalance(credits: Credits(units: 100)))
		let requests = server.requests.withLock { $0 }
		#expect(requests.count == 2)
		for request in requests {
			#expect(request.hasPrefix("GET /key HTTP/1.1\r\n"))
			#expect(request.contains("Authorization: Bearer sk-or-test-cache\r\n"))
		}
	}
}
