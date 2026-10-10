import Foundation
import Testing

@testable import EnduragentCoach

@Suite struct ProviderFailureTests {
	@Test(arguments: [
		StatusRow(401, body: "openrouter-unauthorized", is: .credentialRejected(status: 401)),
		StatusRow(403, body: "openrouter-forbidden", is: .requestBlocked),
		StatusRow(402, body: "openrouter-insufficient-credits", is: .accessExhausted),
		StatusRow(
			429, body: "openrouter-rate-limited", headers: ["Retry-After": "7"],
			is: .rateLimited(retryAfter: .seconds(7))),
		StatusRow(
			429, body: "openrouter-rate-limited",
			headers: ["Retry-After": "7", "retry-after-ms": "1500"],
			is: .rateLimited(retryAfter: .milliseconds(1_500))),
		StatusRow(
			429, body: "openrouter-rate-limited",
			headers: ["Retry-After": "Wed, 21 Oct 1998 07:28:00 GMT"],
			is: .rateLimited(retryAfter: nil)),
		StatusRow(
			502, body: "openrouter-server-error", headers: ["Retry-After": "3"],
			is: .serverError(status: 502, retryAfter: .seconds(3))),
		StatusRow(
			503, body: "openrouter-server-error", is: .serverError(status: 503, retryAfter: nil)),
		StatusRow(400, body: "openrouter-context-overflow", is: .contextOverflow),
		StatusRow(400, body: "openrouter-bad-request", is: .invalidRequest),
		StatusRow(408, is: .timeout(.request)),
		StatusRow(404, is: .invalidRequest),
		StatusRow(409, is: .invalidRequest),
		StatusRow(413, is: .invalidRequest),
		StatusRow(422, is: .invalidRequest),
		StatusRow(302, is: .malformedStream),
	])
	func httpStatusBecomesATypedFailure(row: StatusRow) async throws {
		let body = try row.body.map { try fixture($0, ext: "json") } ?? "{}"
		#expect(
			try await failure(of: .reply(.json(row.status, body, headers: row.headers)))
				== row.expected)
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

	@Test(arguments: [
		(URLError.Code.timedOut, ProviderFailure.timeout(.request)),
		(.badServerResponse, .malformedStream),
	])
	func requestErrorsBecomeTypedFailures(code: URLError.Code, expected: ProviderFailure)
		async throws
	{
		#expect(try await failure(of: .fail(code)) == expected)
	}

	@Test(arguments: [
		URLError.Code.notConnectedToInternet, .networkConnectionLost, .cannotFindHost,
		.cannotConnectToHost, .dnsLookupFailed,
	])
	func connectivityCodesBecomeNetwork(code: URLError.Code) async throws {
		#expect(try await failure(of: .fail(code)) == .network)
	}

	@Test(arguments: [
		("openrouter-finish-unknown", ProviderFailure.unknownFinish),
		("openrouter-finish-missing", .unknownFinish),
		("openrouter-malformed-chunk", .malformedStream),
	])
	func brokenStreamsBecomeTypedFailures(name: String, expected: ProviderFailure) async throws {
		#expect(try await failure(of: .reply(.sse(try fixture(name, ext: "sse")))) == expected)
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

struct StatusRow: Sendable, CustomTestStringConvertible {
	let status: Int
	let body: String?
	let headers: [String: String]
	let expected: ProviderFailure

	init(
		_ status: Int, body: String? = nil, headers: [String: String] = [:],
		is expected: ProviderFailure
	) {
		self.status = status
		self.body = body
		self.headers = headers
		self.expected = expected
	}

	var testDescription: String {
		"\(status) \(body ?? "{}") \(headers.sorted { $0.key < $1.key })"
	}
}
