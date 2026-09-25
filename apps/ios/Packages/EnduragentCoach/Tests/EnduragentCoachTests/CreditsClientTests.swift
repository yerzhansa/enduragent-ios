import Foundation
import Synchronization
import Testing

@testable import EnduragentCoach

@Suite(.serialized)
struct CreditsClientTests {
	@Test("grant minted stores key before returning")
	func grantMintedStoresKeyBeforeReturning() async throws {
		let athleteId = try #require(UUID(uuidString: "11111111-2222-4333-8444-555555555555"))
		let secrets = FakeSecretStore(appAccountToken: athleteId)
		let deviceCheck = Data([0x01, 0x02, 0x03])
		let client = try makeClient(secrets: secrets)
		let captured = Mutex<URLRequest?>(nil)
		let outcome = try await CreditsURLStub.withHandler({ request in
			captured.withLock { $0 = request }
			return .json(
				200,
				#"{"kind":"grantMinted","key":"sk-or-test-0000","credits":200}"#
			)
		}) {
			try await client.grant(deviceCheck: deviceCheck)
		}
		#expect(outcome == .minted(Credits(units: 200)))
		#expect(secrets.storedOpenRouterKeys == 1)
		#expect(try secrets.openRouterKey() == "sk-or-test-0000")
		let request = captured.withLock { $0 }
		#expect(request?.url?.path == "/grant")
		let body = try jsonObject(from: request)
		#expect(body["athleteId"] as? String == athleteId.uuidString.lowercased())
		#expect(body["deviceCheckToken"] as? String == deviceCheck.base64EncodedString())
	}

	@Test("grant alreadyGranted with empty keychain surfaces outcome")
	func grantAlreadyGrantedWithEmptyKeychainSurfacesOutcome() async throws {
		let secrets = FakeSecretStore()
		let client = try makeClient(secrets: secrets)
		let outcome = try await CreditsURLStub.withHandler({ _ in
			.json(200, #"{"kind":"grantAlreadyGranted"}"#)
		}) {
			try await client.grant(deviceCheck: Data([0x01]))
		}
		#expect(outcome == .alreadyGranted)
		#expect(secrets.storedOpenRouterKeys == 0)
		#expect(try secrets.openRouterKey() == nil)
	}

	@Test("grant toppedUp keeps existing key")
	func grantToppedUpKeepsExistingKey() async throws {
		let secrets = FakeSecretStore()
		try secrets.storeOpenRouterKey("sk-or-test-existing")
		let stored = secrets.storedOpenRouterKeys
		let client = try makeClient(secrets: secrets)
		let outcome = try await CreditsURLStub.withHandler({ _ in
			.json(200, #"{"kind":"grantToppedUp","added":200}"#)
		}) {
			try await client.grant(deviceCheck: Data([0x01]))
		}
		#expect(outcome == .toppedUp(added: Credits(units: 200)))
		#expect(secrets.storedOpenRouterKeys == stored)
		#expect(try secrets.openRouterKey() == "sk-or-test-existing")
	}

	@Test("banned maps from error code not status")
	func bannedMapsFromErrorCodeNotStatus() async throws {
		let client = try makeClient(secrets: FakeSecretStore())
		try await CreditsURLStub.withHandler({ _ in
			.json(403, #"{"error":"banned"}"#)
		}) {
			do {
				_ = try await client.grant(deviceCheck: Data([0x01]))
				Issue.record("expected banned")
			} catch let failure as CreditsFailure {
				#expect(failure == .banned)
			} catch {
				Issue.record("wrong error type")
			}
		}
		try await CreditsURLStub.withHandler({ _ in
			.json(429, #"{"error":"rate_limited"}"#)
		}) {
			do {
				_ = try await client.grant(deviceCheck: Data([0x01]))
				Issue.record("expected rateLimited")
			} catch let failure as CreditsFailure {
				#expect(failure == .rateLimited)
			} catch {
				Issue.record("wrong error type")
			}
		}
		try await CreditsURLStub.withHandler({ _ in
			.json(500, "oops")
		}) {
			do {
				_ = try await client.grant(deviceCheck: Data([0x01]))
				Issue.record("expected unexpectedResponse")
			} catch let failure as CreditsFailure {
				#expect(failure == .unexpectedResponse(status: 500))
			} catch {
				Issue.record("wrong error type")
			}
		}
	}

	@Test("claim settlement finishes only after terminal outcome")
	func claimSettlementFinishesOnlyAfterTerminalOutcome() {
		#expect(
			ClaimSettlement.settlement(after: .alreadyClaimed, hasKey: false) == .recoverThenFinish
		)
		#expect(ClaimSettlement.settlement(after: .alreadyClaimed, hasKey: true) == .finish)
		#expect(
			ClaimSettlement.settlement(
				after: .minted(creditsAdded: Credits(units: 200)),
				hasKey: false
			) == .finish
		)
	}

	@Test("recover stores key and athlete id")
	func recoverStoresKeyAndAthleteId() async throws {
		let secrets = FakeSecretStore()
		let athleteId = try #require(UUID(uuidString: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"))
		let client = try makeClient(secrets: secrets)
		let recovery = try await CreditsURLStub.withHandler({ _ in
			.json(
				200,
				#"{"kind":"recovered","athleteId":"aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee","key":"sk-or-test-0000","credits":150}"#
			)
		}) {
			try await client.recover(signedTransaction: "header.payload.signature")
		}
		#expect(recovery == Recovery(athleteId: athleteId, credits: Credits(units: 150)))
		#expect(try secrets.appAccountToken() == athleteId)
		#expect(secrets.storedOpenRouterKeys == 1)
		#expect(try secrets.openRouterKey() == "sk-or-test-0000")
	}

	@Test("balance floors 1.999 to 199 credits")
	func balanceFloors1999To199Credits() async throws {
		let secrets = FakeSecretStore()
		try secrets.storeOpenRouterKey("sk-or-test-0000")
		let client = try makeClient(secrets: secrets)
		let scale = CreditScale(creditsPerUsd: 100)
		let floored = try await CreditsURLStub.withHandler({ _ in
			.json(200, #"{"data":{"limit_remaining":1.999}}"#)
		}) {
			try await client.balance(scale: scale)
		}
		#expect(floored == CreditBalance(credits: Credits(units: 199)))
		let nilRemaining = try await CreditsURLStub.withHandler({ _ in
			.json(200, #"{"data":{"limit_remaining":null}}"#)
		}) {
			try await client.balance(scale: scale)
		}
		#expect(nilRemaining == CreditBalance(credits: Credits(units: 0)))
		let empty = FakeSecretStore()
		let missing = try makeClient(secrets: empty)
		do {
			_ = try await missing.balance(scale: scale)
			Issue.record("expected noAthleteKey")
		} catch let failure as CreditsFailure {
			#expect(failure == .noAthleteKey)
		} catch {
			Issue.record("wrong error type")
		}
	}

	@Test("catalog decodes disabled packs")
	func catalogDecodesDisabledPacks() async throws {
		let client = try makeClient(secrets: FakeSecretStore())
		let catalog = try await CreditsURLStub.withHandler({ request in
			#expect(request.url?.path == "/catalog")
			return .json(
				200,
				#"{"purchasesEnabled":false,"creditsPerUsd":100,"packs":[{"productId":"icu.enduragent.credits.small","credits":500},{"productId":"icu.enduragent.credits.large","credits":2000}]}"#
			)
		}) {
			try await client.catalog()
		}
		#expect(
			catalog
				== PackCatalog(
					purchasesEnabled: false,
					scale: CreditScale(creditsPerUsd: 100),
					packs: [
						CreditPack(
							id: "icu.enduragent.credits.small", credits: Credits(units: 500)),
						CreditPack(
							id: "icu.enduragent.credits.large", credits: Credits(units: 2000)),
					]
				)
		)
	}
}

private func makeClient(secrets: FakeSecretStore) throws -> PhoneCreditsClient {
	let configuration = URLSessionConfiguration.ephemeral
	configuration.protocolClasses = [CreditsURLStub.self]
	configuration.timeoutIntervalForRequest = 20
	let session = URLSession(configuration: configuration)
	return PhoneCreditsClient(
		secrets: secrets,
		workerBase: try #require(URL(string: "https://credits.test")),
		openRouterBase: try #require(URL(string: "https://openrouter.test/api/v1")),
		session: session
	)
}

private func jsonObject(from request: URLRequest?) throws -> [String: Any] {
	guard let request, let data = httpBody(from: request) else {
		throw CreditsFailure.unexpectedResponse(status: 0)
	}
	let object = try JSONSerialization.jsonObject(with: data)
	guard let body = object as? [String: Any] else {
		throw CreditsFailure.unexpectedResponse(status: 0)
	}
	return body
}

private func httpBody(from request: URLRequest) -> Data? {
	if let body = request.httpBody {
		return body
	}
	guard let stream = request.httpBodyStream else {
		return nil
	}
	stream.open()
	defer { stream.close() }
	let bufferSize = 1024
	let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
	defer { buffer.deallocate() }
	var data = Data()
	while stream.hasBytesAvailable {
		let read = stream.read(buffer, maxLength: bufferSize)
		if read <= 0 {
			break
		}
		data.append(buffer, count: read)
	}
	return data
}

private final class CreditsURLStub: URLProtocol, @unchecked Sendable {
	struct Response: Sendable {
		var statusCode: Int
		var headers: [String: String]
		var body: Data

		static func json(_ statusCode: Int, _ body: String) -> Response {
			Response(
				statusCode: statusCode,
				headers: ["Content-Type": "application/json"],
				body: Data(body.utf8)
			)
		}
	}

	private static let handler = Mutex<(@Sendable (URLRequest) -> Response)?>(nil)

	static func withHandler<T: Sendable>(
		_ handler: @escaping @Sendable (URLRequest) -> Response,
		perform: () async throws -> T
	) async throws -> T {
		let previous = Self.handler.withLock { current in
			let previous = current
			current = handler
			return previous
		}
		defer {
			Self.handler.withLock { $0 = previous }
		}
		return try await perform()
	}

	override class func canInit(with request: URLRequest) -> Bool { true }
	override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

	override func startLoading() {
		let handler = Self.handler.withLock { $0 }
		guard let handler else {
			client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
			return
		}
		let response = handler(request)
		guard let url = request.url,
			let http = HTTPURLResponse(
				url: url,
				statusCode: response.statusCode,
				httpVersion: "HTTP/1.1",
				headerFields: response.headers
			)
		else {
			client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
			return
		}
		client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
		client?.urlProtocol(self, didLoad: response.body)
		client?.urlProtocolDidFinishLoading(self)
	}

	override func stopLoading() {}
}
