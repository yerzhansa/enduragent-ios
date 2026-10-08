import AuthenticationServices
import EnduragentCoach
import UIKit

@MainActor
protocol OpenRouterWebAuthenticationSession: AnyObject {
	var presentationContextProvider: (any ASWebAuthenticationPresentationContextProviding)? {
		get set
	}
	func start() -> Bool
	func cancel()
}

extension ASWebAuthenticationSession: OpenRouterWebAuthenticationSession {}

@MainActor
final class OpenRouterSignInSession: OpenRouterAuthorizer {
	typealias MakeSession = (
		URL, ASWebAuthenticationSession.Callback,
		@escaping ASWebAuthenticationSession.CompletionHandler
	) -> any OpenRouterWebAuthenticationSession

	private let presentationAnchor: () -> ASPresentationAnchor?
	private let makeSession: MakeSession

	init(
		presentationAnchor: @escaping () -> ASPresentationAnchor? = {
			UIApplication.shared.connectedScenes
				.compactMap { $0 as? UIWindowScene }
				.filter { $0.activationState == .foregroundActive }
				.flatMap(\.windows)
				.first { $0.isKeyWindow }
		},
		makeSession: @escaping MakeSession = { url, callback, completion in
			ASWebAuthenticationSession(
				url: url, callback: callback, completionHandler: completion)
		}
	) {
		self.presentationAnchor = presentationAnchor
		self.makeSession = makeSession
	}

	func authorize(_ request: OpenRouterAuthRequest) async throws(SignInFailure)
		-> OpenRouterAuthCode
	{
		guard !Task.isCancelled else { throw .canceled }
		guard let anchor = presentationAnchor() else { throw .presentationUnavailable }
		guard let host = request.callbackURL.host else { throw .callbackRejected }
		let presentation = SignInPresentation(anchor: anchor)
		let (results, completion) = AsyncStream<Result<OpenRouterAuthCode, SignInFailure>>
			.makeStream(bufferingPolicy: .bufferingOldest(1))
		let session = makeSession(
			request.authorizationURL,
			.https(host: host, path: request.callbackURL.path)
		) { url, error in
			completion.yield(Self.result(url, error: error, expected: request.callbackURL))
			completion.finish()
		}
		session.presentationContextProvider = presentation
		defer { session.cancel() }
		guard session.start() else { throw .presentationUnavailable }
		let result = await withTaskCancellationHandler {
			var iterator = results.makeAsyncIterator()
			return await iterator.next(isolation: MainActor.shared) ?? .failure(.canceled)
		} onCancel: {
			completion.yield(.failure(.canceled))
			completion.finish()
		}
		withExtendedLifetime(presentation) {}
		return try result.get()
	}

	nonisolated private static func result(
		_ url: URL?, error: (any Error)?, expected: URL
	) -> Result<OpenRouterAuthCode, SignInFailure> {
		if let error {
			let failure = error as NSError
			if failure.domain == ASWebAuthenticationSessionError.errorDomain,
				failure.code == ASWebAuthenticationSessionError.Code.canceledLogin.rawValue
			{
				return .failure(.canceled)
			}
			return .failure(.presentationUnavailable)
		}
		guard let url, let callback = URLComponents(url: url, resolvingAgainstBaseURL: false),
			callback.scheme == "https", callback.host == expected.host,
			callback.percentEncodedPath == expected.path,
			callback.port == nil || callback.port == 443,
			callback.user == nil, callback.password == nil
		else { return .failure(.callbackRejected) }
		let codes = (callback.queryItems ?? []).filter { $0.name == "code" }
		guard codes.count == 1, let code = codes.first?.value,
			!code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
		else { return .failure(.callbackRejected) }
		return .success(OpenRouterAuthCode(code: code))
	}
}

@MainActor
private final class SignInPresentation: NSObject, ASWebAuthenticationPresentationContextProviding {
	private let anchor: ASPresentationAnchor

	init(anchor: ASPresentationAnchor) {
		self.anchor = anchor
	}

	func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
		anchor
	}
}
