import Foundation
import ToolSupport
import Transcripts

struct ScannedMessage {
	let session: SessionEntry
	let milestone: String
	let uuid: String
	let second: Int
	let queued: Bool
	let typed: TypedMessage
	let messageClass: MessageClass
	var repeats = false
}

struct Tally {
	var sessions = 0
	var restarts = 0
	var messages = 0
	var classes: [MessageClass: Int] = [:]
	var repeats = 0
	var interrupts = 0
	var compactions = 0
	var replayed = 0
	var seconds: Set<Int> = []
	var cliRuns = 0
	var commits = 0
	var reverts = 0

	static let idleGap = 900

	var activeHours: String {
		let sorted = seconds.sorted()
		let busy = zip(sorted, sorted.dropFirst()).reduce(0) {
			$1.1 - $1.0 <= Self.idleGap ? $0 + $1.1 - $1.0 : $0
		}
		return String(format: "%.1f", Double(busy) / 3_600)
	}

	var correctionShare: String {
		messages == 0
			? "0.00"
			: String(format: "%.2f", Double(classes[.correction, default: 0]) / Double(messages))
	}

	mutating func add(_ message: ScannedMessage) {
		messages += 1
		classes[message.messageClass, default: 0] += 1
		if message.repeats { repeats += 1 }
	}

	mutating func merge(_ other: Tally) {
		messages += other.messages
		other.classes.forEach { classes[$0.key, default: 0] += $0.value }
		repeats += other.repeats
		interrupts += other.interrupts
		compactions += other.compactions
		seconds.formUnion(other.seconds)
		sessions += other.sessions
		restarts += other.restarts
		cliRuns += other.cliRuns
		commits += other.commits
		reverts += other.reverts
	}
}

struct PrivateMessage: Encodable {
	let session: String
	let title: String
	let milestone: String
	let time: String
	let uuid: String
	let kind: String
	let queued: Bool
	let messageClass: String
	let repeats: Bool
	let text: String
}

struct Retro {
	static let directory = ".audit/retro"
	static let repeatWindow = 7 * 86_400

	let root: String
	let transcripts: String
	let worktreePrefix: String
	let plan: RetroPlan
	let patterns: TextPatterns

	init(root: String, transcripts: String, worktreePrefix: String) throws {
		self.root = root
		self.transcripts = transcripts
		self.worktreePrefix = worktreePrefix
		plan = try RetroPlan(
			milestones: Self.read(NodePath.join(root, Self.directory, "milestones.tsv")),
			sessions: Self.read(NodePath.join(root, Self.directory, "sessions.tsv")))
		patterns = try TextPatterns()
	}

	func run() throws -> String {
		let folders = try FileManager.default.contentsOfDirectory(atPath: transcripts).sorted()
		var seenUUIDs: Set<String> = []
		var seenTexts: Set<String> = []
		var messages: [ScannedMessage] = []
		var bySession: [String: Tally] = [:]
		var byMilestone: [String: Tally] = [:]
		var undecodable = 0
		let decoder = JSONDecoder()
		for session in plan.sessions {
			guard
				let folder = folders.first(where: {
					FileManager.default.fileExists(atPath: path(of: session, in: $0))
				})
			else { throw RetroFailure(description: "No transcript for session \(session.id)") }
			var own = Tally()
			var sessionMessages: [ScannedMessage] = []
			try TranscriptBytes.forEachLine(of: path(of: session, in: folder)) { line in
				if let second = TranscriptBytes.second(of: line) {
					own.seconds.insert(second)
					byMilestone[plan.milestone(of: session, at: second), default: Tally()].seconds
						.insert(second)
				}
				guard TranscriptBytes.mayHoldEvent(line) else { return }
				let decoded: TranscriptLine
				do {
					decoded = try decoder.decode(TranscriptLine.self, from: Data(line))
				} catch is DecodingError {
					undecodable += 1
					return
				}
				switch decoded.event {
				case .human(let uuid, let second, let queued, let raw):
					guard let typed = TypedMessage(raw: raw, patterns: patterns) else { return }
					let textKey = "\(second)\t\(typed.text)"
					guard seenUUIDs.insert(uuid).inserted, seenTexts.insert(textKey).inserted else {
						own.replayed += 1
						return
					}
					sessionMessages.append(
						ScannedMessage(
							session: session, milestone: plan.milestone(of: session, at: second),
							uuid: uuid, second: second, queued: queued, typed: typed,
							messageClass: patterns.classify(typed)))
				case .interrupt(let uuid, let second):
					guard seenUUIDs.insert(uuid).inserted else { return }
					own.interrupts += 1
					byMilestone[plan.milestone(of: session, at: second), default: Tally()]
						.interrupts += 1
				case .compaction(let uuid, let second):
					guard seenUUIDs.insert(uuid).inserted else { return }
					own.compactions += 1
					byMilestone[plan.milestone(of: session, at: second), default: Tally()]
						.compactions += 1
				case nil:
					return
				}
			}
			for subagent in try subagentTranscripts(of: session, in: folder) {
				try TranscriptBytes.forEachLine(of: subagent) { line in
					guard let second = TranscriptBytes.second(of: line) else { return }
					own.seconds.insert(second)
					byMilestone[plan.milestone(of: session, at: second), default: Tally()].seconds
						.insert(second)
				}
			}
			let delivered = sessionMessages.filter { !$0.queued }
			messages += sessionMessages.filter { queued in
				!queued.queued
					|| !delivered.contains {
						$0.typed.text == queued.typed.text
							&& (-5...600).contains($0.second - queued.second)
					}
			}
			bySession[session.id] = own
		}
		messages.sort { ($0.second, $0.uuid) < ($1.second, $1.uuid) }
		markRepeats(&messages)
		for message in messages {
			bySession[message.session.id, default: Tally()].add(message)
			byMilestone[message.milestone, default: Tally()].add(message)
		}
		for session in plan.sessions {
			let touched = Set(messages.filter { $0.session.id == session.id }.map(\.milestone))
			let homes: Set<String> =
				switch session.placement {
				case .milestone(let name): [name]
				case .byDate: touched
				}
			for home in homes {
				byMilestone[home, default: Tally()].sessions += 1
				if session.role.restartsTheThread {
					byMilestone[home, default: Tally()].restarts += 1
				}
			}
		}
		try countCLIRuns(into: &byMilestone)
		try countCommits(into: &byMilestone)
		try write(messages: messages, bySession: bySession, byMilestone: byMilestone)
		return
			"retro: \(plan.sessions.count) sessions, \(messages.count) human messages, "
			+ "\(byMilestone.values.reduce(0) { $0 + $1.interrupts }) interrupts, "
			+ "\(undecodable) undecodable lines; wrote \(Self.directory)/baseline.tsv, "
			+ "\(Self.directory)/session-metrics.tsv and \(Self.directory)/messages.jsonl"
	}

	private func path(of session: SessionEntry, in folder: String) -> String {
		NodePath.join(transcripts, folder, session.id + ".jsonl")
	}

	private func subagentTranscripts(of session: SessionEntry, in folder: String) throws
		-> [String]
	{
		let directory = NodePath.join(transcripts, folder, session.id, "subagents")
		guard FileManager.default.fileExists(atPath: directory) else { return [] }
		return try FileManager.default.contentsOfDirectory(atPath: directory).sorted()
			.filter { $0.hasSuffix(".jsonl") }.map { NodePath.join(directory, $0) }
	}

	private func markRepeats(_ messages: inout [ScannedMessage]) {
		let words = messages.map { patterns.wordSet($0.typed.text) }
		for index in messages.indices
		where messages[index].messageClass.mayRepeat && words[index].count >= 4 {
			messages[index].repeats = messages.indices.prefix(index).contains { earlier in
				messages[earlier].messageClass.mayRepeat
					&& messages[index].second - messages[earlier].second <= Self.repeatWindow
					&& Double(words[index].intersection(words[earlier]).count)
						/ Double(words[index].union(words[earlier]).count) >= 0.75
			}
		}
	}

	private func countCLIRuns(into byMilestone: inout [String: Tally]) throws {
		let folders = try FileManager.default.contentsOfDirectory(atPath: transcripts).sorted()
			.filter { $0.hasPrefix(worktreePrefix + "--worktrees-") }
		for folder in folders {
			let directory = NodePath.join(transcripts, folder)
			for file in try FileManager.default.contentsOfDirectory(atPath: directory).sorted()
			where file.hasSuffix(".jsonl") {
				var first: Int?
				try TranscriptBytes.forEachLine(of: NodePath.join(directory, file)) { line in
					if first == nil { first = TranscriptBytes.second(of: line) }
				}
				guard let first else { continue }
				byMilestone[plan.milestone(at: first), default: Tally()].cliRuns += 1
			}
		}
	}

	private func countCommits(into byMilestone: inout [String: Tally]) throws {
		var seen: Set<Substring> = []
		for milestone in plan.milestones {
			for range in milestone.commitRanges {
				let log = try Subprocess(directory: root).capture(
					"git", ["log", "--no-merges", "--format=%H%x09%s", "--end-of-options", range])
				for line in log.split(separator: "\n") {
					let cells = line.split(separator: "\t", maxSplits: 1)
					guard let sha = cells.first, seen.insert(sha).inserted else { continue }
					byMilestone[milestone.name, default: Tally()].commits += 1
					if cells.count == 2, cells[1].lowercased().hasPrefix("revert") {
						byMilestone[milestone.name, default: Tally()].reverts += 1
					}
				}
			}
		}
	}

	private func write(
		messages: [ScannedMessage], bySession: [String: Tally], byMilestone: [String: Tally]
	) throws {
		let counted: [MessageClass] = [
			.correction, .goAhead, .status, .explain, .checkup, .operatorStep, .task,
		]
		var baseline = [
			[
				"milestone", "sessions", "restarts_or_forks", "compactions", "human_messages",
				"correction_share",
			] + counted.map(\.rawValue)
				+ ["repeats", "interrupts", "active_hours", "cli_runs", "commits", "reverts"]
		]
		var total = Tally()
		for (name, tally) in plan.milestones.map({ ($0.name, byMilestone[$0.name] ?? Tally()) })
			+ [("Total", Tally())]
		{
			var row = tally
			if name == "Total" {
				row = total
				row.sessions = plan.sessions.count
				row.restarts = plan.sessions.filter(\.role.restartsTheThread).count
			} else {
				total.merge(tally)
			}
			baseline.append(
				[
					name, "\(row.sessions)", "\(row.restarts)", "\(row.compactions)",
					"\(row.messages)", row.correctionShare,
				] + counted.map { "\(row.classes[$0, default: 0])" }
					+ [
						"\(row.repeats)", "\(row.interrupts)", row.activeHours, "\(row.cliRuns)",
						"\(row.commits)", "\(row.reverts)",
					])
		}
		var sessions = [
			["session", "milestone", "role", "human_messages"] + counted.map(\.rawValue)
				+ ["repeats", "interrupts", "compactions", "replayed", "active_hours", "title"]
		]
		for session in plan.sessions {
			let tally = bySession[session.id] ?? Tally()
			let placement =
				switch session.placement {
				case .milestone(let name): name
				case .byDate: "by-date"
				}
			sessions.append(
				[
					String(session.id.prefix(8)), placement, session.role.rawValue,
					"\(tally.messages)",
				]
					+ counted.map { "\(tally.classes[$0, default: 0])" }
					+ [
						"\(tally.repeats)", "\(tally.interrupts)", "\(tally.compactions)",
						"\(tally.replayed)", tally.activeHours, session.title,
					])
		}
		let encoder = JSONEncoder()
		encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
		let lines = try messages.map {
			String(
				decoding: try encoder.encode(
					PrivateMessage(
						session: String($0.session.id.prefix(8)), title: $0.session.title,
						milestone: $0.milestone, time: TimeText.local($0.second), uuid: $0.uuid,
						kind: $0.typed.kind.rawValue, queued: $0.queued,
						messageClass: $0.messageClass.rawValue, repeats: $0.repeats,
						text: patterns.redacted($0.typed.text))), as: UTF8.self)
		}
		try Self.save(Self.table(baseline), NodePath.join(root, Self.directory, "baseline.tsv"))
		try Self.save(
			Self.table(sessions), NodePath.join(root, Self.directory, "session-metrics.tsv"))
		try Self.save(
			lines.map { $0 + "\n" }.joined(), NodePath.join(root, Self.directory, "messages.jsonl"))
	}

	private static func table(_ rows: [[String]]) -> String {
		rows.map { $0.joined(separator: "\t") + "\n" }.joined()
	}

	private static func read(_ path: String) throws -> String {
		try String(contentsOfFile: path, encoding: .utf8)
	}

	private static func save(_ text: String, _ path: String) throws {
		try Data(text.utf8).write(to: URL(fileURLWithPath: path))
	}
}
