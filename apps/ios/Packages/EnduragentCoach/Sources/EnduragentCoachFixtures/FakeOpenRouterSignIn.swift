import EnduragentCoach
import Foundation

extension OpenRouterSignInService {
	public static func fake(
		authorizer: FakeOpenRouterAuthorizer, exchangeFails: Bool = false
	) -> OpenRouterSignInService {
		OpenRouterSignInService(
			authorizer: authorizer,
			exchange: OpenRouterKeyExchange {
				ephemeralSession(
					requestTimeout: 30, resourceTimeout: 30,
					protocolClasses: [
						exchangeFails
							? FailedOpenRouterExchangeProtocol.self
							: FakeOpenRouterExchangeProtocol.self
					])
			})
	}
}

private class FakeOpenRouterExchangeProtocol: URLProtocol, @unchecked Sendable {
	class var statusCode: Int { 200 }

	override class func canInit(with request: URLRequest) -> Bool { true }

	override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

	override func startLoading() {
		guard let url = request.url,
			url.absoluteString == "https://openrouter.ai/api/v1/auth/keys",
			request.httpMethod == "POST",
			let response = HTTPURLResponse(
				url: url, statusCode: Self.statusCode, httpVersion: nil,
				headerFields: ["Content-Type": "application/json"])
		else {
			client?.urlProtocol(self, didFailWithError: URLError(.badURL))
			return
		}
		client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
		client?.urlProtocol(
			self, didLoad: Data(#"{"key":"fixture-signed-in-openrouter-key"}"#.utf8))
		client?.urlProtocolDidFinishLoading(self)
	}

	override func stopLoading() {}
}

private final class FailedOpenRouterExchangeProtocol: FakeOpenRouterExchangeProtocol,
	@unchecked Sendable
{
	override class var statusCode: Int { 503 }
}
