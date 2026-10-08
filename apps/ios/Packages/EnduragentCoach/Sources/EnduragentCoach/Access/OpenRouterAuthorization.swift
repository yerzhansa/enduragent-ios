import CryptoKit
import Foundation

public protocol OpenRouterAuthorizer: Sendable {
	func authorize(_ request: OpenRouterAuthRequest) async throws(SignInFailure)
		-> OpenRouterAuthCode
}

public struct OpenRouterAuthRequest: Sendable, Equatable {
	public let authorizationURL: URL
	public let callbackURL: URL
}

public struct OpenRouterAuthCode: Sendable, Equatable {
	public let code: String

	public init(code: String) {
		self.code = code
	}
}

package struct OpenRouterPKCE: Sendable {
	package let verifier: String
	package let request: OpenRouterAuthRequest

	package init() {
		var generator = SystemRandomNumberGenerator()
		let bytes = (0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
		self.init(verifier: Self.base64URL(Data(bytes)))
	}

	package init(verifier: String) {
		self.verifier = verifier
		guard let callback = URL(string: "https://enduragent.icu/auth/openrouter/callback"),
			var authorization = URLComponents(string: "https://openrouter.ai/auth")
		else { fatalError("OpenRouter authorization URLs are invalid") }
		authorization.queryItems = [
			URLQueryItem(name: "callback_url", value: callback.absoluteString),
			URLQueryItem(
				name: "code_challenge",
				value: Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))),
			URLQueryItem(name: "code_challenge_method", value: "S256"),
		]
		guard let url = authorization.url else {
			fatalError("OpenRouter authorization request is invalid")
		}
		self.request = OpenRouterAuthRequest(authorizationURL: url, callbackURL: callback)
	}

	private static func base64URL(_ data: Data) -> String {
		data.base64EncodedString()
			.replacingOccurrences(of: "+", with: "-")
			.replacingOccurrences(of: "/", with: "_")
			.replacingOccurrences(of: "=", with: "")
	}
}
