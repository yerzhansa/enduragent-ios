import Foundation
import Transcripts

enum TurnEndVerdict: Equatable {
	case allow
	case block(reason: String)
}

struct TurnEndCheck {
	private let patterns: TextPatterns
	private let grant: NSRegularExpression
	private let revoke: NSRegularExpression
	private let finished: NSRegularExpression
	private let waiting: NSRegularExpression
	private let operatorOnly: NSRegularExpression
	private let listItem: NSRegularExpression

	init() throws {
		patterns = try TextPatterns()
		grant = try NSRegularExpression(
			pattern:
				#"\b(keep (going|working)|don'?t (stop|pause|ask)|on your own|on yourself|yourself|whatev\w* is needed|approve everything|going to (sleep|bed)|stepping away|without me|autopilot|run until|just do it|take over)\b"#
		)
		revoke = try NSRegularExpression(
			pattern: #"\b(grill|ask me (first|before)|wait for me|check with me)\b|\A\s*pause\b"#)
		finished = try NSRegularExpression(pattern: #"\Adone\."#, options: [.caseInsensitive])
		listItem = try NSRegularExpression(pattern: #"\A([-*•]|\d+[.)])\s"#)
		waiting = try NSRegularExpression(
			pattern: #"(?<!nothing is )(?<!isn't )(?<!not )\bwaiting (on|for) you\b"#,
			options: [.caseInsensitive])
		operatorOnly = try NSRegularExpression(
			pattern:
				#"\b(passcode|password|unlock\w*|cable|plug\w*|usb|wi-?fi|developer mode|face id|touch id|trust|sign(s|ed|ing)? in|log(s|ged|ging)? in|login|two-factor|verification code|secrets?|keys?|tokens?|p8|1password|keychain|pay\w*|purchase\w*|billing|charges?|spend\w*|money|budget|reserved|kept|(your|their) hands)\b|\$\d"#,
			options: [.caseInsensitive])
	}

	func verdict(said: [TypedMessage], reply: String, wakesLater: Bool) -> TurnEndVerdict {
		guard let grant = standingGrant(said) else { return .allow }
		guard let (line, step) = status(of: reply) else {
			if wakesLater { return .allow }
			return .block(
				reason:
					"The operator asked you to keep going without them. They said \"\(grant)\". Your reply does not say whether the work is finished. If anything is left that you can do, do it now. Then add one line to your reply that starts with \"Done.\" and says what is finished, or one line that names the step you are waiting on the operator for, such as \"Waiting on you: unlock the iPhone.\""
			)
		}
		if matches(finished, line) || matches(operatorOnly, step) { return .allow }
		return .block(
			reason:
				"The operator asked you to keep going without them. They said \"\(grant)\". \"\(String(step.prefix(160)))\" hands them a step you can take yourself. Decide open questions yourself: pick the option you would recommend, act on it and say what you chose. Do taps, browser steps, terminal commands and merges they approved yourself. Wait only for a secret or passcode, their hands on a device, money beyond what they approved, or an action they kept for themselves, and say which one."
		)
	}

	private func standingGrant(_ said: [TypedMessage]) -> String? {
		said.reduce(nil) { standing, message in
			let spoken = patterns.spoken(message.text)
			if matches(grant, spoken) {
				return String(
					patterns.redacted(spoken).split(whereSeparator: \.isWhitespace).joined(
						separator: " "
					).prefix(100))
			}
			return matches(revoke, spoken) ? nil : standing
		}
	}

	private func status(of reply: String) -> (line: String, step: String)? {
		let lines = reply.split(whereSeparator: \.isNewline).map {
			$0.trimmingCharacters(in: .whitespaces)
		}.reduce(into: (prose: [String](), fenced: false)) { state, line in
			if line.hasPrefix("```") {
				state.fenced.toggle()
			} else if !state.fenced, !line.isEmpty {
				state.prose.append(line)
			}
		}.prose
		let plain = lines.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \t*_>#-")) }
		guard let index = plain.lastIndex(where: { matches(finished, $0) || matches(waiting, $0) })
		else { return nil }
		let items =
			plain[index].hasSuffix(":")
			? lines[(index + 1)...].prefix { matches(listItem, $0) } : []
		return (plain[index], ([plain[index]] + items).joined(separator: " "))
	}

	private func matches(_ pattern: NSRegularExpression, _ text: String) -> Bool {
		pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
	}
}
