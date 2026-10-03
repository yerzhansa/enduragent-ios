import CryptoKit
import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

@Suite(.timeLimit(.minutes(1))) struct OpenRouterPKCETests {
	@Test(arguments: [200, 201])
	func knownS256VectorAuthorizesAndExchangesCode(_ status: Int) async throws {
		let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
		let pkce = OpenRouterPKCE(verifier: verifier)
		let query = try authorizationQuery(pkce.request)
		#expect(
			query == [
				"callback_url": "https://enduragent.icu/auth/openrouter/callback",
				"code_challenge": "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM",
				"code_challenge_method": "S256",
			])
		#expect(
			pkce.request.callbackURL.absoluteString
				== "https://enduragent.icu/auth/openrouter/callback")
		let authorizer = FakeOpenRouterAuthorizer(response: .held)
		let authorization = Task { try await authorizer.authorize(pkce.request) }
		defer { authorization.cancel() }
		let deadline = ContinuousClock.now + TestWaitLimit.hangGuard.duration
		while await authorizer.requests.isEmpty {
			guard ContinuousClock.now < deadline else { throw TestWaitDeadlineExceeded() }
			try await Task.sleep(for: .milliseconds(5))
		}
		#expect(await authorizer.requests == [pkce.request])
		let returned = OpenRouterAuthCode(code: "synthetic-code/\"+")
		await authorizer.complete(.success(returned), at: 0)
		let code = try await authorization.value
		let stub = OpenRouterStub.keyExchange { _ in
			.reply(.json(status, #"{"key":"synthetic-candidate"}"#))
		}
		let key = try await stub.exchange.key(code, for: pkce)
		#expect(key.value == "synthetic-candidate")
		#expect(stub.requests.recorded.count == 1)
		let request = try #require(stub.requests.recorded.first)
		#expect(request.url?.absoluteString == "https://openrouter.ai/api/v1/auth/keys")
		#expect(request.httpMethod == "POST")
		#expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
		#expect(request.value(forHTTPHeaderField: "Authorization") == nil)
		#expect(
			try exchangeBody(request) == [
				"code": "synthetic-code/\"+",
				"code_verifier": verifier,
				"code_challenge_method": "S256",
			])
	}

	@Test func freshSignInsKeepTheirVerifiersPaired() async throws {
		let attempts = [OpenRouterPKCE(), OpenRouterPKCE()]
		let stub = OpenRouterStub.keyExchange { _ in
			.reply(.json(200, #"{"key":"synthetic-candidate"}"#))
		}
		for pkce in attempts {
			_ = try await stub.exchange.key(OpenRouterAuthCode(code: "synthetic-code"), for: pkce)
		}
		let requests = stub.requests.recorded
		try #require(requests.count == 2)
		var verifiers: [String] = []
		for (pkce, request) in zip(attempts, requests) {
			let body = try exchangeBody(request)
			let verifier = try #require(body["code_verifier"])
			#expect(verifier.count == 43)
			#expect(
				verifier.utf8.allSatisfy { byte in
					(65...90).contains(byte) || (97...122).contains(byte)
						|| (48...57).contains(byte)
						|| byte == 45 || byte == 95
				})
			let expected = Data(SHA256.hash(data: Data(verifier.utf8))).base64EncodedString()
				.replacingOccurrences(of: "+", with: "-")
				.replacingOccurrences(of: "/", with: "_")
				.replacingOccurrences(of: "=", with: "")
			#expect(try authorizationQuery(pkce.request)["code_challenge"] == expected)
			verifiers.append(verifier)
		}
		#expect(verifiers[0] != verifiers[1])
	}

	@Test(arguments: [301, 307, 400, 403, 429, 500, 503])
	func unsuccessfulHTTPResponseFailsWithoutRetry(_ status: Int) async throws {
		let stub = OpenRouterStub.keyExchange { _ in
			.reply(.json(status, #"{"key":"synthetic-untrusted-candidate"}"#))
		}
		await #expect(throws: CredentialFailure.keyExchange(.http(status: status))) {
			try await stub.exchange.key(
				OpenRouterAuthCode(code: "synthetic-code"), for: OpenRouterPKCE())
		}
		#expect(stub.requests.recorded.count == 1)
	}

	@Test(arguments: [
		"", "not-json", "{}", #"{"key":null}"#, #"{"key":123}"#,
		#"{"key":""}"#, #"{"key":" \n\t "}"#,
	])
	func invalidResponseYieldsNoCandidateOrRetry(_ body: String) async throws {
		let stub = OpenRouterStub.keyExchange { _ in .reply(.json(200, body)) }
		await #expect(throws: CredentialFailure.keyExchange(.invalidResponse)) {
			try await stub.exchange.key(
				OpenRouterAuthCode(code: "synthetic-code"), for: OpenRouterPKCE())
		}
		#expect(stub.requests.recorded.count == 1)
	}

	@Test(arguments: [URLError.Code.notConnectedToInternet, .timedOut, .cancelled])
	func networkFailureIsTypedAndNeverRetried(_ code: URLError.Code) async throws {
		let stub = OpenRouterStub.keyExchange { _ in .fail(code) }
		let expected: CredentialFailure =
			code == .cancelled ? .signIn(.canceled) : .keyExchange(.network)
		await #expect(throws: expected) {
			try await stub.exchange.key(
				OpenRouterAuthCode(code: "synthetic-code"), for: OpenRouterPKCE())
		}
		#expect(stub.requests.recorded.count == 1)
	}
}

private func authorizationQuery(_ request: OpenRouterAuthRequest) throws -> [String: String] {
	let components = try #require(
		URLComponents(url: request.authorizationURL, resolvingAgainstBaseURL: false))
	#expect(components.scheme == "https")
	#expect(components.host == "openrouter.ai")
	#expect(components.path == "/auth")
	let items = try #require(components.queryItems)
	var query: [String: String] = [:]
	for item in items {
		try #require(query[item.name] == nil)
		query[item.name] = try #require(item.value)
	}
	return query
}

private func exchangeBody(_ request: URLRequest) throws -> [String: String] {
	try JSONDecoder().decode([String: String].self, from: #require(request.httpBody))
}
