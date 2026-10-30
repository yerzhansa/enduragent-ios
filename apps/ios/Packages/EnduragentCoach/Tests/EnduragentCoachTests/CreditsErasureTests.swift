import EnduragentCoachFixtures
import Foundation
import Synchronization
import Testing

@testable import EnduragentCoach

extension CreditsClientTests {
	@Suite struct CreditsErasureTests {
		private static let athleteId = "11111111-2222-4333-8444-555555555555"

		@Test(
			arguments: [("sk-or-test-0000", "Bearer sk-or-test-0000"), (nil, nil)]
				as [(String?, String?)])
		func eraseSendsTheAthleteIdWithItsKeyAndKeepsTheAccount(
			key: String?, authorization: String?
		) async throws {
			let athleteId = try #require(UUID(uuidString: Self.athleteId))
			let secrets = ICloudKeychainStore(backing: FixtureSecretStoreBacking())
			try secrets.storeCreditsAccount(CreditsAccount(appAccountToken: athleteId, key: key))
			let client = try makeClient(secrets: secrets)
			let captured = Mutex<URLRequest?>(nil)
			try await CreditsURLStub.withHandler({ request in
				captured.withLock { $0 = request }
				return .json(200, #"{"kind":"erased"}"#)
			}) {
				try await client.erase()
			}
			let request = try #require(captured.withLock { $0 })
			#expect(request.httpMethod == "POST")
			#expect(request.url?.path == "/erase")
			#expect(request.value(forHTTPHeaderField: "Authorization") == authorization)
			#expect(try jsonObject(from: request)["athleteId"] as? String == Self.athleteId)
			#expect(
				try secrets.creditsAccount() == CreditsAccount(appAccountToken: athleteId, key: key)
			)
		}

		@Test func eraseWithoutACreditsAccountSendsNothing() async throws {
			let secrets = ICloudKeychainStore(backing: FixtureSecretStoreBacking())
			let client = try makeClient(secrets: secrets)
			let requests = Mutex(0)
			try await CreditsURLStub.withHandler({ _ in
				requests.withLock { $0 += 1 }
				return .json(200, #"{"kind":"erased"}"#)
			}) {
				try await client.erase()
			}
			#expect(requests.withLock { $0 } == 0)
			#expect(try secrets.creditsAccount() == nil)
		}

		@Test(arguments: [
			(401, #"{"error":"unauthorized"}"#, CreditsFailure.unexpectedResponse(status: 401)),
			(429, #"{"error":"rate_limited"}"#, .rateLimited),
			(503, #"{"error":"unavailable"}"#, .unavailable),
			(200, #"{"kind":"grantMinted"}"#, .unexpectedResponse(status: 200)),
		])
		func eraseThatTheWorkerDoesNotConfirmThrows(
			status: Int, body: String, failure: CreditsFailure
		) async throws {
			let secrets = ICloudKeychainStore(backing: FixtureSecretStoreBacking())
			let account = CreditsAccount(appAccountToken: UUID(), key: "sk-or-test-0000")
			try secrets.storeCreditsAccount(account)
			let client = try makeClient(secrets: secrets)
			await #expect(throws: failure) {
				try await CreditsURLStub.withHandler({ _ in .json(status, body) }) {
					try await client.erase()
				}
			}
			#expect(try secrets.creditsAccount() == account)
		}

		@Test func eraseWithNoAnswerThrowsTheConnectionError() async throws {
			let secrets = ICloudKeychainStore(backing: FixtureSecretStoreBacking())
			try secrets.storeCreditsAccount(
				CreditsAccount(appAccountToken: UUID(), key: "sk-or-test-0000"))
			let client = try makeClient(secrets: secrets)
			await #expect(throws: URLError.self) {
				try await client.erase()
			}
			#expect(try secrets.creditsAccount()?.key == "sk-or-test-0000")
		}

		@Test(arguments: IdentifiedCall.allCases)
		func athleteDeletedForgetsTheCreditsAccount(_ call: IdentifiedCall) async throws {
			let secrets = ICloudKeychainStore(backing: FixtureSecretStoreBacking())
			try secrets.storeCreditsAccount(
				CreditsAccount(appAccountToken: UUID(), key: "sk-or-test-0000"))
			let vault = testVault(secrets)
			let client = PhoneCreditsClient(
				vault: vault, workerBase: try #require(URL(string: "https://credits.test")),
				session: stubbedSession())
			let builtIn = try #require(ModelCatalog.fixture.orderedEntries.first).id
			#expect(await vault.accessStatus(builtInModel: builtIn).availability == .ready)
			await #expect(throws: CreditsFailure.athleteDeleted) {
				try await CreditsURLStub.withHandler({ _ in
					.json(410, #"{"error":"athlete_deleted"}"#)
				}) {
					try await call.send(to: client)
				}
			}
			#expect(try secrets.creditsAccount() == nil)
			#expect(await vault.accessStatus(builtInModel: builtIn).availability == .needsSetup)
			#expect(
				AthleteNotice.credits(failure: CreditsFailure.athleteDeleted)
					== AthleteNotice.credits(failure: CreditsFailure.noAthleteKey))
		}

		enum IdentifiedCall: CaseIterable, Sendable {
			case grant, claim, recover

			func send(to client: PhoneCreditsClient) async throws {
				switch self {
				case .grant: _ = try await client.grant(deviceCheck: Data([0x01]))
				case .claim:
					_ = try await client.claim(
						signedTransaction: "header.payload.signature", appAccountToken: UUID())
				case .recover:
					_ = try await client.recover(signedTransaction: "header.payload.signature")
				}
			}
		}

		private func stubbedSession() -> URLSession {
			let configuration = URLSessionConfiguration.ephemeral
			configuration.protocolClasses = [CreditsURLStub.self]
			return URLSession(configuration: configuration)
		}
	}
}
