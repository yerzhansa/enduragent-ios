import Foundation

package struct OpenRouterKeyExchange: Sendable {
	private let makeSession: @Sendable () -> URLSession

	package init(
		makeSession: @escaping @Sendable () -> URLSession = {
			ephemeralSession(requestTimeout: 30, resourceTimeout: 30)
		}
	) {
		self.makeSession = makeSession
	}

	package func key(_ code: OpenRouterAuthCode, for pkce: OpenRouterPKCE)
		async
		throws(CredentialFailure) -> NonEmptySecret
	{
		let session = makeSession()
		defer { session.finishTasksAndInvalidate() }
		var request = URLRequest(url: ModelService.openRouterAPI.appending(path: "auth/keys"))
		request.httpMethod = "POST"
		request.setValue("application/json", forHTTPHeaderField: "Content-Type")
		request.httpBody = Data(
			JSONValue.object([
				"code": .string(code.code),
				"code_verifier": .string(pkce.verifier),
				"code_challenge_method": .string("S256"),
			]).canonicalDigestInput().utf8)
		let data: Data
		let response: URLResponse
		do {
			(data, response) = try await session.data(
				for: request, delegate: RejectOpenRouterRedirects())
		} catch is CancellationError {
			throw .signIn(.canceled)
		} catch let error as URLError where error.code == .cancelled {
			throw .signIn(.canceled)
		} catch {
			throw .keyExchange(.network)
		}
		guard let http = response as? HTTPURLResponse else {
			throw .keyExchange(.invalidResponse)
		}
		guard (200..<300).contains(http.statusCode) else {
			throw .keyExchange(.http(status: http.statusCode))
		}
		let reply: KeyReply
		do {
			reply = try JSONDecoder().decode(KeyReply.self, from: data)
		} catch {
			throw .keyExchange(.invalidResponse)
		}
		guard let key = NonEmptySecret(reply.key) else {
			throw .keyExchange(.invalidResponse)
		}
		return key
	}
}

private struct KeyReply: Decodable {
	let key: String
}

private final class RejectOpenRouterRedirects: NSObject, URLSessionTaskDelegate {
	func urlSession(
		_ session: URLSession, task: URLSessionTask,
		willPerformHTTPRedirection response: HTTPURLResponse,
		newRequest request: URLRequest,
		completionHandler: @escaping @Sendable (URLRequest?) -> Void
	) {
		completionHandler(nil)
	}
}
