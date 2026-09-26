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
			let directive = Self.repetition(Array(words.dropFirst()))
			if let failure = Self.failure(directive.arguments) {
				transport.script =
					Array(repeating: .fail(failure), count: directive.count) + transport.script
			}
		case "memory-then-fail":
			transport.script = Self.memoryThenFail
		case "memory-then-hang":
			transport.script = Self.memoryThenHang
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

	static let memoryThenFail = savedSchedule + [.fail(.http(status: 500))]
	static let memoryThenHang = savedSchedule + [.hang]

	private static let savedSchedule: [ScriptedEvent] = [
		.toolCall(
			name: ToolName.memoryWrite.rawValue,
			arguments:
				#"{"type":"memory","section":"schedule","content":"Rides with a group on Saturdays."}"#
		),
		.finish(reason: .toolCalls),
	]

	private static func repetition(_ arguments: [String]) -> (arguments: [String], count: Int) {
		guard let last = arguments.last, last.hasPrefix("x"), let count = Int(last.dropFirst()),
			count > 0
		else {
			return (arguments, 1)
		}
		return (Array(arguments.dropLast()), count)
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
