import Foundation

package enum MessageKind: String {
	case prompt
	case slashCommand = "slash"
	case shell
}

package enum MessageClass: String, CaseIterable {
	case correction
	case checkup
	case status
	case explain
	case operatorStep = "operator"
	case goAhead = "go-ahead"
	case task

	package var mayRepeat: Bool { [.correction, .checkup, .explain, .task].contains(self) }
}

package struct TypedMessage {
	package let kind: MessageKind
	package let text: String

	static let cannedTexts: Set<String> = [
		"I hit my usage limit while you were working, but it has reset now. Please continue from where you left off.",
		"Try again",
	]

	package init?(raw: String, patterns: TextPatterns) {
		let text = patterns.withoutReminders(raw).trimmingCharacters(in: .whitespacesAndNewlines)
		guard !text.isEmpty, !Self.cannedTexts.contains(text) else { return nil }
		if text.hasPrefix("<command-") {
			let command = patterns.tag("command-name", in: text)
			let arguments = patterns.tag("command-args", in: text)
			kind = .slashCommand
			self.text = [command, arguments].filter { !$0.isEmpty }.joined(separator: " ")
		} else if text.hasPrefix("<bash-input>") {
			kind = .shell
			self.text = "! " + patterns.tag("bash-input", in: text)
		} else if ["<local-command-", "<task-notification"].contains(where: text.hasPrefix) {
			return nil
		} else {
			kind = .prompt
			self.text = text
		}
	}
}

package struct TextPatterns {
	private let reminder: NSRegularExpression
	private let quoted: NSRegularExpression
	private let words: NSRegularExpression
	private let rules: [(MessageClass, NSRegularExpression)]
	private let secrets: [NSRegularExpression]

	static let ruleTable: [(MessageClass, String)] = [
		(.operatorStep, #"\b(wrong chat|ignore my questions|ignore this|i asked in wrong)\b"#),
		(.correction, #"\A\s*(no|nope|wrong|stop|don'?t|never)\b"#),
		(
			.correction,
			#"\b(i told you|as i said|again and again|you are wasting|wasting my|what the fuck|stupid|bloat\w*|overkill|over-?engineer\w*|overthink\w*|that was a question|this is wrong|not what i|too long|go faster|weak\b|why (did|didn'?t|can'?t|are|do|would) you)"#
		),
		(
			.correction,
			#"\b(on your own|on yourself|yourself|you must do|you can do that|just do it|whatev\w* is needed|i didn'?t do anything|can'?t baby ?sit|don'?t babysit|don'?t ask|don'?t stop|don'?t pause|don'?t watch|don'?t implement|don'?t change|don'?t relaunch|don'?t touch|cut any ties|without me)\b"#
		),
		(
			.checkup,
			#"(^\s*(so )?(did|didn'?t|have|haven'?t) (you|we)\b|\bdid you (actually|really|re-?run|run|fix|merge|update|create|test|start)\b|\bis .{1,60} doing it\b|anyone is fixing)"#
		),
		(
			.status,
			#"\b(all good|all done|what is nexts?|what'?s next|next\?|so next|what (is|was) (the )?status|status\?|how is it going|eta\b|what happened|are you stuck|what is left|what left|lefto|where are we|blocked\?|what is going on|what was done|done for this thread|remaining work|anything outstanding|is m\d done|what (you have|have you) done|\A\s*\?+\s*\z)"#
		),
		(
			.explain,
			#"(simple terms|/simple|keep it short|one sentence|two sentences|i didn'?t get|didn'?t get it|explain|understand|what does .{1,80} mean|what is (this|that)\b|what is [a-z0-9 _./-]{1,40}\?|what they are|in simple|\A\s*(why|when does|how does|is that)\b)"#
		),
		(
			.operatorStep,
			#"\b(phone is (ready|connected|online)|unlocked|cable|plugged|i deleted|keys? added|deployed|signed in|^stored$|pasted here|wi-?fi|developer mode|awake|tapped|face down|^merged|^ci is green$|^done\b|phone online|i'?ll paste|i will (delete|clear)|ran it|\A\s*ready\b)"#
		),
		(
			.goAhead,
			#"^\s*(go|go ahead|go on|keep go\w*|continue|yes|yep|ok|okay|sure|agree\w*|i agree|i am okay|great|good|send it|do it|do that|do now|do next|do both|merge|fix it|fix all|fix both|approve\w*|confirmed|accepted|go with|option|take [a-z]\b|turn on auto-?fix|apply|land|send|i approve|just do (that|it)|once ready|type it|enforce it|do [a-d](?=\s*\(|\s*\z)|do only|do\z)\b"#
		),
	]

	package init() throws {
		reminder = try NSRegularExpression(
			pattern: #"<system-reminder>.*?</system-reminder>"#,
			options: [.dotMatchesLineSeparators])
		quoted = try NSRegularExpression(
			pattern:
				#"<pasted_content[^>]*>.*?</pasted_content[^>]*>|^\s*>.*$|<!--.*?-->|@\[[^\]]*\]"#,
			options: [.dotMatchesLineSeparators, .anchorsMatchLines])
		words = try NSRegularExpression(pattern: #"[\p{L}\p{N}']{2,}"#)
		rules = try Self.ruleTable.map {
			($0.0, try NSRegularExpression(pattern: $0.1, options: [.anchorsMatchLines]))
		}
		secrets = try [
			#"sk-(?:ant-|or-v1-|proj-)?[A-Za-z0-9_\-]{20,}"#, #"gh[pousr]_[A-Za-z0-9]{30,}"#,
			#"github_pat_[A-Za-z0-9_]{30,}"#, #"xox[abposr]-[A-Za-z0-9\-]{10,}"#,
			#"AKIA[0-9A-Z]{16}"#, #"AIza[0-9A-Za-z_\-]{35}"#,
			#"eyJ[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}"#,
			#"\b\d{8,10}:AA[A-Za-z0-9_\-]{33}\b"#, #"(?i)bearer\s+[A-Za-z0-9._\-]{20,}"#,
			#"-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----"#,
			#"(?i)\b(?:api[_-]?key|access[_-]?token|auth[_-]?token|client[_-]?secret|password)\s*[:=]\s*["']?[^\s"']{8,}"#,
		].map { try NSRegularExpression(pattern: $0) }
	}

	package func withoutReminders(_ text: String) -> String {
		replace(reminder, in: text, with: "")
	}

	package func tag(_ name: String, in text: String) -> String {
		guard let open = text.range(of: "<\(name)>"),
			let close = text.range(of: "</\(name)>", range: open.upperBound..<text.endIndex)
		else { return "" }
		return String(text[open.upperBound..<close.lowerBound]).trimmingCharacters(
			in: .whitespacesAndNewlines)
	}

	package func spoken(_ text: String) -> String {
		replace(quoted, in: text, with: " ").lowercased()
			.replacingOccurrences(of: "\u{2019}", with: "'")
			.trimmingCharacters(in: .whitespacesAndNewlines)
	}

	package func classify(_ message: TypedMessage) -> MessageClass {
		guard message.kind != .shell else { return .operatorStep }
		let spoken = spoken(message.text)
		let range = NSRange(spoken.startIndex..., in: spoken)
		return rules.first { $0.1.firstMatch(in: spoken, range: range) != nil }?.0 ?? .task
	}

	package func wordSet(_ text: String) -> Set<String> {
		let spoken = spoken(text)
		return Set(
			words.matches(in: spoken, range: NSRange(spoken.startIndex..., in: spoken)).compactMap {
				Range($0.range, in: spoken).map { String(spoken[$0]) }
			})
	}

	package func redacted(_ text: String) -> String {
		secrets.reduce(text) { replace($1, in: $0, with: "[REDACTED]") }
	}

	private func replace(_ pattern: NSRegularExpression, in text: String, with template: String)
		-> String
	{
		pattern.stringByReplacingMatches(
			in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
	}
}
