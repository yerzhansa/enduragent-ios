import EnduragentCoach
import Foundation

struct FixtureDirector: Sendable {
	static let prefix = "fixture:"
	static let slowFirstWordDelay: Duration = .seconds(2)
	static let slowWordDelay: Duration = .milliseconds(250)

	let transport: FakeModelTransport
	let records: FaultInjectingRecordLog

	func prepare(for text: String) {
		reset(replyingTo: text)
		guard text.hasPrefix(Self.prefix) else { return }
		let words = text.dropFirst(Self.prefix.count).split(separator: " ").map(String.init)
		switch words.first {
		case "slow":
			transport.requestDelay = Self.slowFirstWordDelay
			transport.deltaDelay = Self.slowWordDelay
			transport.script = FirstWeekFixture.weekSummaryByWord()
		case "hang":
			transport.hangUntilCancelled = true
		case "fail":
			if let failure = Self.failure(Array(words.dropFirst())) {
				transport.failures.append(failure)
			}
		case "storage":
			if words.dropFirst().first == "fail-next-append" {
				records.failNextAppend = true
			}
		default:
			break
		}
	}

	func prepareRetry(of text: String) {
		reset(replyingTo: text)
	}

	private func reset(replyingTo text: String) {
		transport.hangUntilCancelled = false
		transport.requestDelay = nil
		transport.deltaDelay = nil
		transport.script = FirstWeekFixture.script(for: text)
	}

	private static func failure(_ arguments: [String]) -> ScriptedFailure? {
		switch arguments.first {
		case "401":
			return .http(status: 401)
		case "402":
			return .http(status: 402)
		case "429":
			let retryAfter = arguments.dropFirst().first ?? "7"
			return .http(status: 429, headers: ["retry-after": retryAfter])
		case "500":
			return .http(status: 500)
		case "network":
			return .connection(.notConnectedToInternet)
		case "timeout":
			return .connection(.timedOut)
		case "overflow":
			return .http(
				status: 400,
				body:
					#"{"error":{"message":"This endpoint's maximum context length is 131072 tokens."}}"#
			)
		default:
			return nil
		}
	}
}
