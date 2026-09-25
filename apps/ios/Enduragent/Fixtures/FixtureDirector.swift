import EnduragentCoach
import Foundation

enum FixtureDirective: Equatable {
	case sendToCoach
	case handled
}

struct FixtureDirector: Sendable {
	static let prefix = "fixture:"
	static let slowFirstWordDelay: Duration = .seconds(2)
	static let slowWordDelay: Duration = .milliseconds(250)

	let transport: FakeModelTransport
	let records: FaultInjectingRecordLog

	func prepare(for text: String) -> FixtureDirective {
		transport.hangUntilCancelled = false
		transport.requestDelay = nil
		transport.deltaDelay = nil
		transport.script = FirstWeekFixture.script(for: text)
		guard text.hasPrefix(Self.prefix) else { return .sendToCoach }
		let words = text.dropFirst(Self.prefix.count).split(separator: " ").map(String.init)
		switch words.first {
		case "slow":
			transport.requestDelay = Self.slowFirstWordDelay
			transport.deltaDelay = Self.slowWordDelay
			transport.script = FirstWeekFixture.weekSummaryByWord()
			return .sendToCoach
		case "hang":
			transport.hangUntilCancelled = true
			return .sendToCoach
		case "fail":
			if let failure = Self.failure(Array(words.dropFirst())) {
				transport.failures.append(failure)
			}
			return .sendToCoach
		case "storage":
			if words.dropFirst().first == "fail-next-append" {
				records.failNextAppend = true
			}
			return .handled
		default:
			return .sendToCoach
		}
	}

	private static func failure(_ arguments: [String]) -> (any Error)? {
		switch arguments.first {
		case "429":
			let retryAfter = arguments.dropFirst().first ?? "7"
			return OpenRouterHTTPError(statusCode: 429, body: "retry-after: \(retryAfter)")
		case "500":
			return OpenRouterHTTPError(statusCode: 500, body: "")
		case "network":
			return URLError(.notConnectedToInternet)
		case "timeout":
			return URLError(.timedOut)
		case "overflow":
			return OpenRouterHTTPError(
				statusCode: 400,
				body: "This endpoint's maximum context length is 131072 tokens."
			)
		default:
			return nil
		}
	}
}
