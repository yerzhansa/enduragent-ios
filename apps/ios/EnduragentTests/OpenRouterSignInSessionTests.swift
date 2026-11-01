import AuthenticationServices
import EnduragentCoachFixtures
import Testing
import UIKit

@testable import Enduragent
@testable import EnduragentCoach

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct OpenRouterSignInSessionTests {
	@Test func authorizationStartsOneHTTPSSystemSessionAndReturnsOnlyTheCode() async throws {
		let harness = try SignInHarness()
		let result = try await harness.run { _ in
			let session = harness.session
			#expect(session.starts == 1)
			#expect(session.url == harness.request.authorizationURL)
			let callback = try #require(session.callback)
			#expect(callback.matchesURL(harness.request.callbackURL))
			for address in [
				"enduragent://auth/openrouter/callback",
				"https://other.example/auth/openrouter/callback",
				"https://enduragent.icu/auth/other",
			] {
				#expect(!callback.matchesURL(try #require(URL(string: address))))
			}
			let provider = try #require(session.presentationContextProvider)
			let native = ASWebAuthenticationSession(
				url: harness.request.authorizationURL, callback: callback
			) { _, _ in }
			#expect(provider.presentationAnchor(for: native) === harness.anchor)
			session.complete(
				try #require(
					URL(
						string:
							"https://enduragent.icu/auth/openrouter/callback?code=synthetic%2Bcode&state=ignored"
					)))
			session.complete(
				try #require(
					URL(string: "https://enduragent.icu/auth/openrouter/callback?code=late")))
		}
		#expect(result == .success(OpenRouterAuthCode(code: "synthetic+code")))
		#expect(harness.session.starts == 1)
	}

	@Test(arguments: ["anchor", "start", "context-missing", "context-invalid", "other-error"])
	func presentationRefusalReturnsUnavailable(fault: String) async throws {
		let harness = try SignInHarness(hasAnchor: fault != "anchor")
		harness.session.startsSuccessfully = fault != "start"
		let result: Result<OpenRouterAuthCode, SignInFailure>
		if !["anchor", "start"].contains(fault) {
			result = try await harness.run { _ in
				let code =
					fault == "context-missing"
					? ASWebAuthenticationSessionError.Code.presentationContextNotProvided.rawValue
					: fault == "other-error"
						? ASWebAuthenticationSessionError.Code.canceledLogin.rawValue
						: ASWebAuthenticationSessionError.Code.presentationContextInvalid.rawValue
				harness.session.complete(
					nil,
					error: NSError(
						domain: fault == "other-error"
							? "synthetic" : ASWebAuthenticationSessionError.errorDomain,
						code: code))
			}
		} else {
			result = try await harness.run()
		}
		#expect(result == .failure(.presentationUnavailable))
		#expect(harness.session.starts == (fault == "anchor" ? 0 : 1))
		#expect(harness.creations == (fault == "anchor" ? 0 : 1))
	}

	@Test func systemCancellationReturnsTypedCanceled() async throws {
		let harness = try SignInHarness()
		let result = try await harness.run { _ in
			harness.session.complete(
				try #require(
					URL(string: "https://enduragent.icu/auth/openrouter/callback?code=ignored")),
				error: NSError(
					domain: ASWebAuthenticationSessionError.errorDomain,
					code: ASWebAuthenticationSessionError.Code.canceledLogin.rawValue))
		}
		#expect(result == .failure(.canceled))
	}

	@Test(arguments: [
		"nil",
		"https://other.example/auth/openrouter/callback?code=synthetic",
		"https://enduragent.icu/auth/other?code=synthetic",
		"https://enduragent.icu/auth/openrouter/callback/extra?code=synthetic",
		"http://enduragent.icu/auth/openrouter/callback?code=synthetic",
		"enduragent://auth/openrouter/callback?code=synthetic",
		"https://enduragent.icu:444/auth/openrouter/callback?code=synthetic",
		"https://user@enduragent.icu/auth/openrouter/callback?code=synthetic",
		"https://enduragent.icu/auth/openrouter/callback",
		"https://enduragent.icu/auth/openrouter/callback?code",
		"https://enduragent.icu/auth/openrouter/callback?code=",
		"https://enduragent.icu/auth/openrouter/callback?code=%20%0A",
		"https://enduragent.icu/auth/openrouter/callback?code=first&code=second",
	])
	func rejectedCallbacksNeverReturnACode(address: String) async throws {
		let harness = try SignInHarness()
		let url = address == "nil" ? nil : try #require(URL(string: address))
		let result = try await harness.run { _ in harness.session.complete(url) }
		#expect(result == .failure(.callbackRejected))
	}

	@Test func taskCancellationDismissesTheHeldSession() async throws {
		let harness = try SignInHarness()
		let result = try await harness.run { operation in operation.cancel() }
		#expect(result == .failure(.canceled))
		#expect(harness.session.cancels == 1)
	}
}

@MainActor
private final class SignInHarness {
	let request: OpenRouterAuthRequest
	let anchor: UIWindow?
	let session = ControlledWebAuthenticationSession()
	private(set) var creations = 0
	private var authorizer: OpenRouterSignInSession {
		OpenRouterSignInSession(
			presentationAnchor: { self.anchor },
			makeSession: { url, callback, completion in
				self.creations += 1
				self.session.url = url
				self.session.callback = callback
				self.session.completion = completion
				return self.session
			})
	}

	init(hasAnchor: Bool = true) throws {
		if hasAnchor {
			let scene = try #require(
				UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
			anchor = UIWindow(windowScene: scene)
		} else {
			anchor = nil
		}
		request = OpenRouterAuthRequest(
			authorizationURL: try #require(
				URL(
					string:
						"https://openrouter.ai/auth?callback_url=https%3A%2F%2Fenduragent.icu%2Fauth%2Fopenrouter%2Fcallback&code_challenge=synthetic&code_challenge_method=S256"
				)),
			callbackURL: try #require(
				URL(string: "https://enduragent.icu/auth/openrouter/callback")))
	}

	func run(
		whenStarted: ((Task<Result<OpenRouterAuthCode, SignInFailure>, Never>) throws -> Void)? =
			nil
	) async throws -> Result<OpenRouterAuthCode, SignInFailure> {
		let adapter = authorizer
		let operation = Task {
			do throws(SignInFailure) {
				return Result<OpenRouterAuthCode, SignInFailure>.success(
					try await adapter.authorize(request))
			} catch { return .failure(error) }
		}
		return try await withThrowingTaskGroup(of: Result<OpenRouterAuthCode, SignInFailure>?.self)
		{ group in
			defer {
				operation.cancel()
				group.cancelAll()
			}
			group.addTask { await operation.value }
			group.addTask {
				try await Task.sleep(for: TestWaitLimit.hangGuard.duration)
				return nil
			}
			if let whenStarted {
				let deadline = ContinuousClock.now + TestWaitLimit.hangGuard.duration
				while session.starts == 0, ContinuousClock.now < deadline {
					try await Task.sleep(for: .milliseconds(10))
				}
				try #require(session.starts == 1)
				try whenStarted(operation)
			}
			return try #require(
				try await group.next() ?? nil, "Authorization exceeded the test deadline")
		}
	}
}

@MainActor
private final class ControlledWebAuthenticationSession: OpenRouterWebAuthenticationSession {
	weak var presentationContextProvider: (any ASWebAuthenticationPresentationContextProviding)?
	var url: URL?
	var callback: ASWebAuthenticationSession.Callback?
	var completion: ASWebAuthenticationSession.CompletionHandler?
	var startsSuccessfully = true
	private(set) var starts = 0
	private(set) var cancels = 0

	func start() -> Bool {
		starts += 1
		return startsSuccessfully
	}

	func cancel() { cancels += 1 }

	func complete(_ url: URL?, error: (any Error)? = nil) { completion?(url, error) }
}
