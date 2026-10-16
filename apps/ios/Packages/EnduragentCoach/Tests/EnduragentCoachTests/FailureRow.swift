import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

struct FailureRow: Sendable, CustomTestStringConvertible {
	let scripted: ScriptedFailure
	let failure: ModelFailure
	let key: CatalogKey
	let buttons: [String]
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
			key: Catalog.creditsErrorAccessRejected, buttons: ["Restore purchases"],
			english: "Your Credits couldn't be used. Restore purchases to continue."),
		FailureRow(
			scripted: .http(status: 402), failure: .accessExhausted(.credits),
			key: Catalog.creditsErrorExhausted, buttons: ["Buy Credits", "Switch to OpenRouter"],
			english: "You're out of Credits. You can switch to your OpenRouter account."),
		FailureRow(
			scripted: .http(status: 429, headers: ["retry-after": "7"]),
			failure: .rateLimited(retryAfter: .seconds(7)),
			key: Catalog.coachErrorRateLimitSeconds, buttons: ["Try again"],
			english: "Rate limited — please try again in ~7 seconds."),
		FailureRow(
			scripted: .http(status: 429, headers: ["retry-after": "90"]),
			failure: .rateLimited(retryAfter: .seconds(90)),
			key: Catalog.coachErrorRateLimitMinutes, buttons: ["Try again"],
			english: "Rate limited — please try again in ~2 minutes."),
		FailureRow(
			scripted: .http(status: 429), failure: .rateLimited(retryAfter: nil),
			key: Catalog.coachErrorRateLimitDefault, buttons: ["Try again"],
			english: "Rate limited — please try again in about a minute."),
		FailureRow(
			scripted: .http(status: 500), failure: .providerDown(.outage),
			key: Catalog.coachErrorProviderDown, buttons: ["Try again"],
			english: "The model provider is having trouble — try again in a few minutes."),
		FailureRow(
			scripted: .connection(.notConnectedToInternet), failure: .providerDown(.network),
			key: Catalog.coachErrorProviderDown, buttons: ["Try again"],
			english: "The model provider is having trouble — try again in a few minutes."),
		FailureRow(
			scripted: .connection(.timedOut), failure: .providerDown(.timeout),
			key: Catalog.coachErrorProviderDown, buttons: ["Try again"],
			english: "The model provider is having trouble — try again in a few minutes."),
		FailureRow(
			scripted: .http(status: 400, body: #"{"error":{"message":"maximum context length"}}"#),
			failure: .contextOverflow,
			key: Catalog.coachErrorUnknown, buttons: ["Try again"],
			english: "Sorry, something went wrong. Please try again."),
		FailureRow(
			scripted: .http(status: 400), failure: .invalidRequest,
			key: Catalog.coachErrorUnknown, buttons: ["Try again"],
			english: "Sorry, something went wrong. Please try again."),
		FailureRow(
			scripted: ScriptedFailure(.malformedStream),
			failure: .generationFailed(.malformedStream),
			key: Catalog.chatNoticeResponseFailure, buttons: ["Try again"],
			english: "The coach couldn't respond. Please try again."),
	]
}
