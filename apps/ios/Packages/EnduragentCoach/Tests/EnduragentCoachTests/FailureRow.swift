import Foundation
import Testing

@testable import EnduragentCoach

struct FailureRow: Sendable, CustomTestStringConvertible {
	let scripted: ScriptedFailure
	let failure: ModelFailure
	let key: CatalogKey
	let button: String?
	let english: String

	var calls: Int {
		switch failure {
		case .rateLimited, .contextOverflow: 4
		case .providerDown(.timeout): 2
		case .providerDown: 3
		default: 1
		}
	}

	var testDescription: String { "\(failure)" }

	static let all: [FailureRow] = [
		FailureRow(
			scripted: .http(status: 401), failure: .credentialRejected(.credits),
			key: Catalog.creditsErrorAccessRejected, button: "Restore purchases",
			english: "Your Credits couldn't be used. Restore purchases to continue."),
		FailureRow(
			scripted: .http(status: 402), failure: .accessExhausted(.credits),
			key: Catalog.creditsErrorExhausted, button: "Buy Credits",
			english: "You're out of Credits. Buy more, or switch to your OpenRouter account."),
		FailureRow(
			scripted: .http(status: 429, headers: ["retry-after": "7"]),
			failure: .rateLimited(retryAfter: .seconds(7)),
			key: Catalog.coachErrorRateLimitSeconds, button: "Try again",
			english: "Rate limited — please try again in ~7 seconds."),
		FailureRow(
			scripted: .http(status: 429, headers: ["retry-after": "90"]),
			failure: .rateLimited(retryAfter: .seconds(90)),
			key: Catalog.coachErrorRateLimitMinutes, button: "Try again",
			english: "Rate limited — please try again in ~2 minutes."),
		FailureRow(
			scripted: .http(status: 429), failure: .rateLimited(retryAfter: nil),
			key: Catalog.coachErrorRateLimitDefault, button: "Try again",
			english: "Rate limited — please try again in about a minute."),
		FailureRow(
			scripted: .http(status: 500), failure: .providerDown(.outage),
			key: Catalog.coachErrorProviderDown, button: "Try again",
			english: "The model provider is having trouble — try again in a few minutes."),
		FailureRow(
			scripted: .connection(.notConnectedToInternet), failure: .providerDown(.network),
			key: Catalog.coachErrorProviderDown, button: "Try again",
			english: "The model provider is having trouble — try again in a few minutes."),
		FailureRow(
			scripted: .connection(.timedOut), failure: .providerDown(.timeout),
			key: Catalog.coachErrorProviderDown, button: "Try again",
			english: "The model provider is having trouble — try again in a few minutes."),
		FailureRow(
			scripted: .http(status: 400, body: #"{"error":{"message":"maximum context length"}}"#),
			failure: .contextOverflow,
			key: Catalog.coachErrorUnknown, button: "Try again",
			english: "Sorry, something went wrong. Please try again."),
		FailureRow(
			scripted: .http(status: 400), failure: .invalidRequest,
			key: Catalog.coachErrorUnknown, button: "Try again",
			english: "Sorry, something went wrong. Please try again."),
		FailureRow(
			scripted: ScriptedFailure(.malformedStream),
			failure: .generationFailed(.malformedStream),
			key: Catalog.chatNoticeResponseFailure, button: "Try again",
			english: "The coach couldn't respond. Please try again."),
	]
}
