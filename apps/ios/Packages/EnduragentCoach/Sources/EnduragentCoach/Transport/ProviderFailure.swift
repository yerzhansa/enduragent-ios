import Foundation

package enum ProviderFailure: Error, Sendable, Equatable {
	case credentialRejected(status: Int)
	case accessExhausted
	case rateLimited(retryAfter: Duration?)
	case serverError(status: Int, retryAfter: Duration?)
	case network
	case timeout(TimeoutKind)
	case contextOverflow
	case invalidRequest
	case unknownFinish
	case malformedStream
}

package enum TimeoutKind: Sendable, Equatable {
	case firstToken
	case interChunk
	case request
}

extension ProviderFailure {
	private static let overflowPhrases = [
		"context_length",
		"context window",
		"maximum context",
		"token limit",
		"too many tokens",
		"content_too_large",
		"prompt is too long",
		"exceeds the maximum",
		"input token count",
	]

	private static let unreadableResponseCodes: Set<URLError.Code> = [
		.badServerResponse,
		.cannotParseResponse,
		.cannotDecodeContentData,
		.cannotDecodeRawData,
		.zeroByteResource,
	]

	package init(status: Int, headers: [String: String], body: String) {
		let header = Dictionary(
			headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { _, last in last })
		switch status {
		case 400:
			let lowered = body.lowercased()
			self =
				Self.overflowPhrases.contains(where: lowered.contains)
				? .contextOverflow : .invalidRequest
		case 401, 403:
			self = .credentialRejected(status: status)
		case 402:
			self = .accessExhausted
		case 408:
			self = .timeout(.request)
		case 429:
			self = .rateLimited(retryAfter: Self.retryAfter(header))
		case 500...599:
			self = .serverError(status: status, retryAfter: Self.retryAfter(header))
		case 400...499:
			self = .invalidRequest
		default:
			self = .malformedStream
		}
	}

	package init(_ error: URLError) {
		if error.code == .timedOut {
			self = .timeout(.request)
		} else if Self.unreadableResponseCodes.contains(error.code) {
			self = .malformedStream
		} else {
			self = .network
		}
	}

	private static func retryAfter(_ headers: [String: String]) -> Duration? {
		if let milliseconds = leadingInteger(headers["retry-after-ms"]), milliseconds > 0 {
			return .milliseconds(milliseconds)
		}
		if let seconds = leadingInteger(headers["retry-after"]), seconds > 0 {
			return .seconds(seconds)
		}
		return nil
	}

	private static func leadingInteger(_ raw: String?) -> Int? {
		guard let raw else { return nil }
		let digits = raw.trimmingCharacters(in: .whitespaces).prefix { $0.isASCII && $0.isNumber }
		return Int(digits)
	}
}
