import Foundation
import Testing
import Transcripts

@testable import Retro

struct RetroTests {
	static let parent = "11111111-0000-0000-0000-000000000000"
	static let fork = "22222222-0000-0000-0000-000000000000"

	static func human(_ uuid: String, _ time: String, _ text: String) -> String {
		#"{"type":"user","uuid":"\#(uuid)","timestamp":"2026-10-01T\#(time).000Z","origin":{"kind":"human"},"message":{"role":"user","content":"\#(text)"}}"#
	}

	static let parentLines = [
		human("u1", "08:00:00", "build the settings screen"),
		#"{"type":"user","uuid":"u2","timestamp":"2026-10-01T08:05:00.000Z","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user]"}]}}"#,
		#"{"type":"attachment","uuid":"u3","timestamp":"2026-10-01T08:06:00.000Z","attachment":{"type":"queued_command","prompt":"no, keep the old layout","origin":{"kind":"human"}}}"#,
		human("u4", "08:06:30", "no, keep the old layout"),
		#"{"type":"user","uuid":"u5","timestamp":"2026-10-01T08:07:00.000Z","isCompactSummary":true,"message":{"role":"user","content":"This session is being continued [Request interrupted by user]"}}"#,
		#"{"type":"user","uuid":"u6","timestamp":"2026-10-01T08:08:00.000Z","message":{"role":"user","content":[{"type":"tool_result","content":"quoted [Request interrupted by user]"}]}}"#,
	]

	static let forkLines = [
		human("u1", "08:00:00", "build the settings screen"),
		human("u7", "09:00:00", "did you run the tests?"),
	]

	static func withTree(_ body: (_ root: String, _ transcripts: String) throws -> Void) throws {
		let base = FileManager.default.temporaryDirectory.appendingPathComponent(
			"retro-\(UUID().uuidString)"
		).path
		let retro = base + "/repo/.audit/retro"
		let project = base + "/projects/-repo"
		try FileManager.default.createDirectory(atPath: retro, withIntermediateDirectories: true)
		try FileManager.default.createDirectory(atPath: project, withIntermediateDirectories: true)
		try Data("milestone\tstarts\tcommits\nM1\t2026-09-25T00:00:00+05:00\t\n".utf8).write(
			to: URL(fileURLWithPath: retro + "/milestones.tsv"))
		try Data(
			("session\tcreated\tmilestone\trole\ttitle\n"
				+ "\(parent)\t2026-10-01 13:00\tM1\tlead\tParent\n"
				+ "\(fork)\t2026-10-01 14:00\tM1\tfork\tParent (fork)\n").utf8
		).write(to: URL(fileURLWithPath: retro + "/sessions.tsv"))
		try Data(parentLines.joined(separator: "\n").utf8).write(
			to: URL(fileURLWithPath: project + "/\(parent).jsonl"))
		try Data(forkLines.joined(separator: "\n").utf8).write(
			to: URL(fileURLWithPath: project + "/\(fork).jsonl"))
		let outcome = Result { try body(base + "/repo", base + "/projects") }
		try FileManager.default.removeItem(atPath: base)
		try outcome.get()
	}

	static func table(_ path: String) throws -> [[String: String]] {
		let rows = try String(contentsOfFile: path, encoding: .utf8).split(separator: "\n").map {
			$0.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
		}
		return rows.dropFirst().map { Dictionary(uniqueKeysWithValues: zip(rows[0], $0)) }
	}

	@Test
	func countsEachTypedMessageOnceAcrossAForkAndAQueue() throws {
		try Self.withTree { root, transcripts in
			_ = try Retro(root: root, transcripts: transcripts, worktreePrefix: "-repo").run()

			let baseline = try Self.table(root + "/.audit/retro/baseline.tsv")
			let milestone = try #require(baseline.first { $0["milestone"] == "M1" })
			#expect(milestone["human_messages"] == "3")
			#expect(milestone["correction"] == "1")
			#expect(milestone["checkup"] == "1")
			#expect(milestone["task"] == "1")
			#expect(milestone["interrupts"] == "1")
			#expect(milestone["compactions"] == "1")
			#expect(milestone["restarts_or_forks"] == "1")
			let fork = try #require(
				try Self.table(root + "/.audit/retro/session-metrics.tsv").first {
					$0["session"] == "22222222"
				})
			#expect(fork["replayed"] == "1")
			#expect(fork["human_messages"] == "1")
		}
	}

	@Test(arguments: [
		("no, keep the old layout", MessageClass.correction),
		("finish the rest on your own", .correction),
		("did you run the unit tests?", .checkup),
		("what's next after the build?", .status),
		("explain the cache layer", .explain),
		("the phone is connected", .operatorStep),
		("go ahead with plan B", .goAhead),
		("add a dark theme", .task),
		("<bash-input>git status</bash-input>", .operatorStep),
	])
	func classifiesWhatTheOperatorHadToSay(_ text: String, _ expected: MessageClass) throws {
		let patterns = try TextPatterns()
		let message = try #require(TypedMessage(raw: text, patterns: patterns))
		#expect(patterns.classify(message) == expected)
	}
}
