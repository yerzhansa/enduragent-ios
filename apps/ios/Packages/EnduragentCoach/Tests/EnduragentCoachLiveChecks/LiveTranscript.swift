import Foundation

@testable import EnduragentCoach

enum LiveTranscript {
	static func markdown(
		_ scenario: LiveScenario, attempt: Int, turns: [LiveTurnRecord], cancel: LiveCancelRecord?,
		violations: [String]
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
			lines += ["", "### Workout review after the turn", "", review(turn.reviewAfter)]
			if let notice = turn.notice { lines += ["", "Review notice: \(notice.rawValue)"] }
		}
		if let cancel {
			lines += [
				"", "## Cancel", "", "Outcome: \(cancel.outcome)", "",
				"Calendar requests during Cancel: \(cancel.calendarRequests)",
			]
		}
		return lines.joined(separator: "\n") + "\n"
	}

	private static func review(_ review: WorkoutReview?) -> String {
		guard let review else { return "None." }
		let changes = review.work.remaining.map {
			"- \($0.id.ulid.rawValue): \(LiveChangeShape($0.action))"
		}
		return
			(["Review \(review.id.ulid.rawValue), revision \(review.revision.rawValue):"]
			+ changes).joined(separator: "\n")
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
