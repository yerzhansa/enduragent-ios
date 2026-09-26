import EnduragentCoach
import Foundation

enum FixtureDirective: Equatable {
	case sendToCoach
	case rejected(String)
}

struct FixtureDirector: Sendable {
	static let prefix = "fixture:"
	static let slowFirstWordDelay: Duration = .seconds(2)
	static let slowWordDelay: Duration = .milliseconds(250)

	let transport: FakeModelTransport
	let records: FaultInjectingRecordLog

	func prepare(for text: String) -> FixtureDirective {
		reset(replyingTo: text)
		guard text.hasPrefix(Self.prefix) else { return .sendToCoach }
		let words = text.dropFirst(Self.prefix.count).split(separator: " ").map(String.init)
		let arguments = Array(words.dropFirst())
		switch words.first {
		case "slow" where arguments.isEmpty:
			transport.requestDelay = Self.slowFirstWordDelay
			transport.deltaDelay = Self.slowWordDelay
			transport.script = FirstWeekFixture.weekSummaryByWord()
		case "hang" where arguments.isEmpty:
			transport.hangUntilCancelled = true
		case "fail":
			guard let failure = Self.failure(arguments) else {
				return .rejected(Self.unknown(text))
			}
			transport.failures.append(failure)
		case "storage" where arguments == ["fail-next-append"]:
			records.failNextAppend = true
		default:
			return .rejected(Self.unknown(text))
		}
		return .sendToCoach
	}

	func prepareRetry(of text: String) {
		reset(replyingTo: text)
	}

	private func reset(replyingTo text: String) {
		transport.hangUntilCancelled = false
		transport.requestDelay = nil
		transport.deltaDelay = nil
		transport.failures = []
		transport.script = FirstWeekFixture.script(for: text)
	}

	private static func unknown(_ text: String) -> String {
		"Unknown fixture directive: \(text)"
	}

	private static func failure(_ arguments: [String]) -> ScriptedFailure? {
		guard let code = arguments.first else { return nil }
		let rest = Array(arguments.dropFirst())
		switch code {
		case "401" where rest.isEmpty:
			return .http(status: 401)
		case "402" where rest.isEmpty:
			return .http(status: 402)
		case "429" where rest.isEmpty:
			return .http(status: 429, headers: ["retry-after": "7"])
		case "429" where rest.count == 1 && Int(rest[0]) != nil:
			return .http(status: 429, headers: ["retry-after": rest[0]])
		case "500" where rest.isEmpty:
			return .http(status: 500)
		case "network" where rest.isEmpty:
			return .connection(.notConnectedToInternet)
		case "timeout" where rest.isEmpty:
			return .connection(.timedOut)
		case "overflow" where rest.isEmpty:
			return .http(
				status: 400,
				body:
					#"{"error":{"message":"This endpoint's maximum context length is 131072 tokens."}}"#
			)
		case "finish" where rest.isEmpty:
			return .unknownFinish
		default:
			return nil
		}
	}
}
