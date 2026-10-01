import Foundation
import Testing

@testable import EnduragentCoach

extension CreditsClientTests {
	@Test(arguments: [100, 250])
	func balanceAppliesTheCatalogScale(creditsPerUsd: Int) async throws {
		let client = try makeClient(secrets: keyedSecrets())
		let balance = try await CreditsURLStub.withHandler({ request in
			if request.url?.path == "/catalog" {
				#expect(request.value(forHTTPHeaderField: "Authorization") == nil)
				return .json(
					200,
					"{\"purchasesEnabled\":false,\"creditsPerUsd\":\(creditsPerUsd),\"packs\":[]}")
			}
			#expect(request.url?.path == "/api/v1/key")
			#expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(testKey)")
			return .json(200, #"{"data":{"limit_remaining":1.999}}"#)
		}) {
			try await client.balance()
		}
		#expect(balance.credits.units == (creditsPerUsd == 100 ? 199 : 499))
	}

	@Test func balancePropagatesCatalogFailure() async throws {
		let client = try makeClient(secrets: keyedSecrets())
		await #expect(throws: CreditsFailure.unavailable) {
			try await CreditsURLStub.withHandler({ request in
				#expect(request.url?.path == "/catalog")
				return .json(503, #"{"error":"unavailable"}"#)
			}) {
				try await client.balance()
			}
		}
	}
}
