import Foundation
import Testing

@testable import EnduragentCoach

@Suite struct ProviderFailureTests {
	@Test(arguments: [
		(401, "openrouter-unauthorized"),
		(403, "openrouter-forbidden"),
	])
	func rejectedKeyIsCredentialRejected(status: Int, body: String) async throws {
		let failure = try await failure(of: .reply(.json(status, try fixture(body, ext: "json"))))
		#expect(failure == .credentialRejected(status: status))
	}

	@Test func status402IsAccessExhausted() async throws {
		let body = try fixture("openrouter-insufficient-credits", ext: "json")
		#expect(try await failure(of: .reply(.json(402, body))) == .accessExhausted)
	}

	@Test func status429ReadsRetryAfterSeconds() async throws {
		let body = try fixture("openrouter-rate-limited", ext: "json")
		let failure = try await failure(of: .reply(.json(429, body, headers: ["Retry-After": "7"])))
		#expect(failure == .rateLimited(retryAfter: .seconds(7)))
	}

	@Test func retryAfterMsWinsOverRetryAfterSeconds() async throws {
		let body = try fixture("openrouter-rate-limited", ext: "json")
		let headers = ["Retry-After": "7", "retry-after-ms": "1500"]
		let failure = try await failure(of: .reply(.json(429, body, headers: headers)))
		#expect(failure == .rateLimited(retryAfter: .milliseconds(1_500)))
	}

	@Test func status429WithoutAHintHasNoRetryAfter() async throws {
		let body = try fixture("openrouter-rate-limited", ext: "json")
		let headers = ["Retry-After": "Wed, 21 Oct 1998 07:28:00 GMT"]
		let failure = try await failure(of: .reply(.json(429, body, headers: headers)))
		#expect(failure == .rateLimited(retryAfter: nil))
	}

	@Test func status5xxIsServerErrorWithRetryAfter() async throws {
		let body = try fixture("openrouter-server-error", ext: "json")
		let failure = try await failure(of: .reply(.json(502, body, headers: ["Retry-After": "3"])))
		#expect(failure == .serverError(status: 502, retryAfter: .seconds(3)))
		#expect(
			try await self.failure(of: .reply(.json(503, body)))
				== .serverError(status: 503, retryAfter: nil))
	}

	@Test func overflowBodyBecomesContextOverflow() async throws {
		let body = try fixture("openrouter-context-overflow", ext: "json")
		#expect(try await failure(of: .reply(.json(400, body))) == .contextOverflow)
	}

	@Test func other400BecomesInvalidRequest() async throws {
		let body = try fixture("openrouter-bad-request", ext: "json")
		#expect(try await failure(of: .reply(.json(400, body))) == .invalidRequest)
	}

	@Test func status408IsRequestTimeout() async throws {
		#expect(try await failure(of: .reply(.json(408, "{}"))) == .timeout(.request))
	}

	@Test(arguments: [404, 409, 413, 422])
	func otherClientErrorsBecomeInvalidRequest(status: Int) async throws {
		#expect(try await failure(of: .reply(.json(status, "{}"))) == .invalidRequest)
	}

	@Test func statusOutsideClientAndServerErrorsIsMalformedStream() async throws {
		#expect(try await failure(of: .reply(.json(302, "{}"))) == .malformedStream)
	}

	@Test func cancelledRequestEndsAsCancellationAndRecordsNothing() async throws {
		let diagnostics = DiagnosticsLog(clock: SystemClock())
		let transport = try OpenRouterStub.transport(diagnostics: diagnostics) { _ in
			.fail(.cancelled)
		}
		await #expect(throws: CancellationError.self) {
			_ = try await collect(
				transport.stream(
					testRequest([
						WireMessage(role: .user, content: "Hi Ada", toolCalls: [], toolCallId: nil)
					])))
		}
		#expect(diagnostics.entries.isEmpty)
	}

	@Test func timedOutBecomesRequestTimeout() async throws {
		#expect(try await failure(of: .fail(.timedOut)) == .timeout(.request))
	}

	@Test(arguments: [
		URLError.Code.notConnectedToInternet, .networkConnectionLost, .cannotFindHost,
		.cannotConnectToHost, .dnsLookupFailed,
	])
	func connectivityCodesBecomeNetwork(code: URLError.Code) async throws {
		#expect(try await failure(of: .fail(code)) == .network)
	}

	@Test func unknownFinishReasonBecomesUnknownFinish() async throws {
		let sse = try fixture("openrouter-finish-unknown", ext: "sse")
		#expect(try await failure(of: .reply(.sse(sse))) == .unknownFinish)
	}

	@Test func missingFinishReasonBecomesUnknownFinish() async throws {
		let sse = try fixture("openrouter-finish-missing", ext: "sse")
		#expect(try await failure(of: .reply(.sse(sse))) == .unknownFinish)
	}

	@Test func malformedChunkBecomesMalformedStream() async throws {
		let sse = try fixture("openrouter-malformed-chunk", ext: "sse")
		#expect(try await failure(of: .reply(.sse(sse))) == .malformedStream)
	}

	private func failure(of outcome: OpenRouterStub.Outcome) async throws -> ProviderFailure {
		let transport = try OpenRouterStub.transport { _ in outcome }
		return try await #require(throws: ProviderFailure.self) {
			_ = try await collect(
				transport.stream(
					testRequest([
						WireMessage(role: .user, content: "Hi Ada", toolCalls: [], toolCallId: nil)
					])))
		}
	}
}
