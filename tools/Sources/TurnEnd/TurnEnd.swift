import Foundation
import ToolSupport
import Transcripts

struct StopHookInput: Decodable {
	struct Pending: Decodable {}

	let transcriptPath: String
	let lastAssistantMessage: String
	let stopHookActive: Bool?
	let backgroundTasks: [Pending]?
	let sessionCrons: [Pending]?

	enum CodingKeys: String, CodingKey {
		case transcriptPath = "transcript_path"
		case lastAssistantMessage = "last_assistant_message"
		case stopHookActive = "stop_hook_active"
		case backgroundTasks = "background_tasks"
		case sessionCrons = "session_crons"
	}

	var workWillWakeTheAgent: Bool {
		!(backgroundTasks ?? []).isEmpty || !(sessionCrons ?? []).isEmpty
	}
}

struct StopHookBlock: Encodable {
	let decision = "block"
	let reason: String
}

struct TurnEnd {
	let check: TurnEndCheck
	let patterns: TextPatterns

	init() throws {
		check = try TurnEndCheck()
		patterns = try TextPatterns()
	}

	func answer(_ hookInput: Data) throws -> String? {
		let input = try JSONDecoder().decode(StopHookInput.self, from: hookInput)
		guard input.stopHookActive != true else { return nil }
		var said: [TypedMessage] = []
		let decoder = JSONDecoder()
		try TranscriptBytes.forEachLine(of: input.transcriptPath) { line in
			guard TranscriptBytes.mayHoldEvent(line) else { return }
			let decoded: TranscriptLine
			do {
				decoded = try decoder.decode(TranscriptLine.self, from: Data(line))
			} catch is DecodingError {
				return
			}
			if case .human(_, _, _, let raw) = decoded.event,
				let typed = TypedMessage(raw: raw, patterns: patterns)
			{
				said.append(typed)
			}
		}
		guard
			case .block(let reason) = check.verdict(
				said: said, reply: input.lastAssistantMessage,
				wakesLater: input.workWillWakeTheAgent)
		else { return nil }
		let encoder = JSONEncoder()
		encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
		return String(decoding: try encoder.encode(StopHookBlock(reason: reason)), as: UTF8.self)
	}
}

@main
struct TurnEndCommand {
	static func main() throws {
		do {
			let input = try FileHandle.standardInput.readToEnd() ?? Data()
			if let block = try TurnEnd().answer(input) {
				try Console.say(block)
			}
		} catch {
			try Console.complain("turn-end: \(Console.text(of: error))")
			exit(1)
		}
	}
}
