import Foundation

@testable import EnduragentCoach

enum LiveTranscript {
	static func markdown(
		_ scenario: LiveScenario, attempt: Int, turns: [LiveTurnRecord], violations: [String]
	) -> String {
		var lines = [
			"# \(scenario.name), run \(attempt)", "", "Setting: \(scenario.setting.rawValue)", "",
			"## Violations", "",
		]
		lines += violations.isEmpty ? ["None."] : violations.map { "- \($0)" }
		for (number, turn) in turns.enumerated() {
			lines += ["", "## Turn \(number + 1)", "", "Athlete: \(turn.message)", ""]
			lines += ["Outcome: \(turn.outcome)", ""]
			lines += [
				"Tools offered: \(turn.offeredTools.sorted().joined(separator: ", "))", "",
				"### System prompt", "", fenced(turn.systemPrompt),
			]
			var seen = 0
			for (index, exchange) in turn.exchanges.enumerated() {
				let request = exchange.request
				lines += [
					"",
					"### Model call \(index + 1) (\(request.charge), \(request.model.rawValue))",
					"",
				]
				for message in request.messages.dropFirst(max(seen, 1)) {
					lines += render(message)
				}
				seen = request.messages.count
				for event in exchange.events {
					switch event {
					case .toolCall(let call):
						lines += ["", "Tool call `\(call.name)`: `\(call.arguments)`"]
					case .finished(let reason, let usage):
						lines += [
							"",
							"Finished: \(reason), \(usage.inputTokens) in, \(usage.outputTokens) out, cost \(usage.cost.map { String(format: "$%.6f", $0) } ?? "not reported")",
						]
					case .textDelta, .heartbeat:
						continue
					}
				}
				if let failure = exchange.failure { lines += ["", "Failure: \(failure)"] }
			}
			lines += ["", "### Reply", "", turn.reply ?? "(no reply)"]
		}
		return lines.joined(separator: "\n") + "\n"
	}

	private static func render(_ message: WireMessage) -> [String] {
		var lines = ["", "**\(message.role.rawValue)**", ""]
		if !message.content.isEmpty { lines.append(fenced(message.content)) }
		for call in message.toolCalls {
			lines.append("Tool call `\(call.name)`: `\(call.arguments)`")
		}
		return lines
	}

	private static func fenced(_ text: String) -> String {
		"````text\n\(text)\n````"
	}
}
