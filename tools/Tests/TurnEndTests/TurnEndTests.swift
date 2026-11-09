import Foundation
import Testing
import Transcripts

@testable import TurnEnd

struct TurnEndTests {
	struct Turn: CustomTestStringConvertible, Sendable {
		let name: String
		let operatorSaid: [String]
		let reply: String
		let blocks: Bool

		var testDescription: String { name }
	}

	static let turns = [
		Turn(
			name: "a stop that leaves the operator to ask what is next",
			operatorSaid: ["keep going until the build is green"],
			reply:
				"The build is running.\n\nI'll look again in ten minutes.",
			blocks: true),
		Turn(
			name: "a tap left for the operator",
			operatorSaid: ["run the app yourself"],
			reply: "Still waiting on you for one tap on the phone: \"Allow\".",
			blocks: true),
		Turn(
			name: "a tap handed back on the waiting line",
			operatorSaid: ["run the app yourself"],
			reply: "**Waiting on you:** one tap on the phone, \"Allow\".",
			blocks: true),
		Turn(
			name: "a go-ahead handed back on the waiting line",
			operatorSaid: ["take over the release"],
			reply: "Waiting on you: your pick between plan A and plan B and a go-ahead to start.",
			blocks: true),
		Turn(
			name: "a check the agent can run by hand",
			operatorSaid: ["keep going"],
			reply: "Still waiting on you: the screen check by hand.",
			blocks: true),
		Turn(
			name: "a wait for a physical step said in passing",
			operatorSaid: ["keep going"],
			reply:
				"Nothing has changed: I'm waiting for you to plug in and unlock the iPhone.",
			blocks: false),
		Turn(
			name: "a waiting line whose list names a physical step",
			operatorSaid: ["keep going"],
			reply:
				"Two more things are waiting on you:\n\n- unlock the iPhone\n- plug it into the Mac",
			blocks: false),
		Turn(
			name: "a prompt drafted for the operator to send",
			operatorSaid: ["keep going"],
			reply:
				"Here is the prompt for the new session:\n\n```text\nGoal: ship the release.\nDone means: the build is in TestFlight.\n```\n\nWant me to send it?",
			blocks: true),
		Turn(
			name: "progress so far with work left",
			operatorSaid: ["keep going"],
			reply: "Done so far:\n- the settings screen\n\nShould I start the history screen next?",
			blocks: true),
		Turn(
			name: "a claim that nothing waits on the operator",
			operatorSaid: ["keep going"],
			reply: "Both runs are going. Nothing is waiting on you.",
			blocks: true),
		Turn(
			name: "a step that needs the operator's hands",
			operatorSaid: ["keep going"],
			reply: "Waiting on you: unlock the iPhone and plug it into the Mac by cable.",
			blocks: false),
		Turn(
			name: "finished work with an attention section after it",
			operatorSaid: ["keep going"],
			reply:
				"Both fixes merged.\n\n**Done.** The release branch has both fixes.\n\n## Notes\n\n- None.",
			blocks: false),
		Turn(
			name: "a question with no grant from the operator",
			operatorSaid: ["what is next?"],
			reply: "Which option do you want, A or B?",
			blocks: false),
		Turn(
			name: "a question after the operator asked to be grilled",
			operatorSaid: ["keep going", "grill me on the open questions"],
			reply: "Question 1: should the plan card stay after a reload?",
			blocks: false),
	]

	@Test(arguments: turns)
	func holdsTheTurnEndToTheOperatorsGrant(_ turn: Turn) throws {
		let patterns = try TextPatterns()
		let said = try turn.operatorSaid.map {
			try #require(TypedMessage(raw: $0, patterns: patterns))
		}
		#expect(
			(try TurnEndCheck().verdict(said: said, reply: turn.reply, wakesLater: false) != .allow)
				== turn.blocks)
	}

	static let handBack = "Tap Allow on the phone, then tell me."

	static func answer(
		reply: String, stopHookActive: Bool = false, backgroundTasks: [[String: String]] = []
	) throws -> String? {
		let path = FileManager.default.temporaryDirectory.appendingPathComponent(
			"turn-end-\(UUID().uuidString).jsonl"
		).path
		try Data(session.joined(separator: "\n").utf8).write(to: URL(fileURLWithPath: path))
		let input = try JSONSerialization.data(
			withJSONObject: [
				"transcript_path": path, "last_assistant_message": reply,
				"stop_hook_active": stopHookActive, "background_tasks": backgroundTasks,
				"session_crons": [[String: String]](),
			] as [String: Any])
		let answer = Result { try TurnEnd().answer(input) }
		try FileManager.default.removeItem(atPath: path)
		return try answer.get()
	}

	static let session = [
		#"{"type":"user","uuid":"u1","timestamp":"2026-10-10T08:00:00.000Z","origin":{"kind":"human"},"message":{"role":"user","content":"finish it on your own"}}"#,
		#"{"type":"assistant","uuid":"a1","timestamp":"2026-10-10T08:01:00.000Z","message":{"role":"assistant","content":[{"type":"text","text":"Tap Allow on the phone, then tell me."}]}}"#,
		#"{"type":"user","uuid":"u2","timestamp":"2026-10-10T08:01:01.000Z","message":{"role":"user","content":[{"type":"tool_result","content":"done"}]}}"#,
	]

	@Test
	func blocksTheStopAndQuotesTheOperator() throws {
		let block = try #require(try Self.answer(reply: Self.handBack))
		let decoded = try #require(
			try JSONSerialization.jsonObject(with: Data(block.utf8)) as? [String: String])
		#expect(decoded["decision"] == "block")
		#expect(decoded["reason"]?.contains("\"finish it on your own\"") == true)
	}

	@Test
	func trustsTheFinalReplyOverALaggingTranscript() throws {
		#expect(try Self.answer(reply: "Done. The phone step is finished.") == nil)
	}

	@Test
	func letsTheSecondStopThrough() throws {
		#expect(try Self.answer(reply: Self.handBack, stopHookActive: true) == nil)
	}

	static let review = [
		"id": "a1", "type": "subagent", "status": "running",
		"description": "review the pull request",
	]

	@Test
	func letsASilentStopThroughWhileBackgroundWorkWillWakeTheAgent() throws {
		#expect(
			try Self.answer(reply: "The build is running.", backgroundTasks: [Self.review])
				== nil)
	}

	@Test
	func blocksAHandBackEvenWhileBackgroundWorkRuns() throws {
		let reply = "Still waiting on you for one tap on the phone: \"Allow\"."
		#expect(try Self.answer(reply: reply, backgroundTasks: [Self.review]) != nil)
	}
}
