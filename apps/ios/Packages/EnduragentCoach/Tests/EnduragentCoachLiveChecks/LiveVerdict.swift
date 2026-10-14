import Foundation

@testable import EnduragentCoach

enum LiveVerdict {
	static func violations(of turn: LiveTurnRecord, against expectations: [LiveExpectation])
		-> [String]
	{
		var found: [String] = []
		guard let reply = turn.reply else { return ["the turn ended \(turn.outcome)"] }
		if turn.athleteMessage != turn.message {
			found.append("the coach did not receive the athlete's message unchanged")
		}
		if reply.range(of: #"\bUTC\b"#, options: .regularExpression) != nil {
			found.append("the reply labels a time UTC")
		}
		let gated = turn.toolCalls.filter { GatedToolName(rawValue: $0.name) != nil }
		if !gated.isEmpty {
			found.append("calendar tools were called: \(gated.map(\.name).joined(separator: ", "))")
		}
		if turn.reviewPending { found.append("a workout review is waiting") }
		if turn.calendarWrites > 0 { found.append("the calendar was written") }
		let calls = turn.toolCalls.map(ParsedCall.init)
		for call in calls where call.arguments == nil {
			found.append("\(call.name) was called with arguments that are not JSON")
		}
		return found + expectations.compactMap { check($0, on: turn, calls: calls, reply: reply) }
	}

	private struct ParsedCall {
		let name: String
		let parsed: Result<[String: JSONValue], any Error>

		init(_ call: WireToolCall) {
			name = call.name
			parsed = Result { try call.parseArguments().objectFields }
		}

		var arguments: [String: JSONValue]? {
			guard case .success(let fields) = parsed else { return nil }
			return fields
		}
	}

	private static func shown(_ values: [JSONValue]) -> String {
		values.map(canonicalJSON).joined(separator: " or ")
	}

	private static func check(
		_ expectation: LiveExpectation, on turn: LiveTurnRecord, calls: [ParsedCall], reply: String
	) -> String? {
		func arguments(of tool: ToolName) -> [[String: JSONValue]] {
			calls.filter { $0.name == tool.rawValue }.map { $0.arguments ?? [:] }
		}
		switch expectation {
		case .calls(let tool):
			return arguments(of: tool).isEmpty ? "\(tool.rawValue) was not called" : nil
		case .neverCalls(let tool):
			return arguments(of: tool).isEmpty ? nil : "\(tool.rawValue) was called"
		case .callsWith(let tool, let key, let values):
			return arguments(of: tool).contains { values.contains($0[key] ?? .null) }
				? nil : "\(tool.rawValue) was not called with \(key) \(shown(values))"
		case .neverCallsWith(let tool, let key, let values):
			return arguments(of: tool).contains { values.contains($0[key] ?? .null) }
				? "\(tool.rawValue) was called with \(key) \(shown(values))" : nil
		case .listsActivitiesCovering(let date, let today):
			let covered = arguments(of: .intervalsFetchActivities).contains { fields in
				let oldest = fields["oldest"]?.stringValue.flatMap(CivilDate.init(rawValue:))
				let newest =
					fields["newest"]?.stringValue.flatMap(CivilDate.init(rawValue:)) ?? today
				return oldest.map { $0 <= date && date <= newest } ?? false
			}
			return covered ? nil : "no activity list covered \(date.rawValue)"
		case .offersNoTrainingTools:
			let offered = turn.offeredTools.filter { $0.hasPrefix("intervals_") }
			return offered.isEmpty
				? nil : "training tools were offered: \(offered.sorted().joined(separator: ", "))"
		case .promptHolds(let text):
			return turn.systemPrompt.contains(text) ? nil : "the prompt does not hold \"\(text)\""
		case .promptLacks(let text):
			return turn.systemPrompt.contains(text) ? "the prompt holds \"\(text)\"" : nil
		case .replyMentions(let words):
			let missing = words.filter { reply.range(of: $0, options: .caseInsensitive) == nil }
			return missing.isEmpty
				? nil : "the reply does not mention \(missing.joined(separator: ", "))"
		}
	}
}
