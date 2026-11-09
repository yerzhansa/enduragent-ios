import Foundation
import ToolSupport
import Transcripts

struct RetroFailure: DescribedFailure {
	let description: String
}

struct MilestoneWindow {
	let name: String
	let start: Int
	let commitRanges: [String]
}

enum Placement: Equatable {
	case milestone(String)
	case byDate
}

enum SessionRole: String {
	case lead
	case restart
	case fork
	case side
	case retro

	var restartsTheThread: Bool { self == .restart || self == .fork }
}

struct SessionEntry {
	let id: String
	let created: String
	let placement: Placement
	let role: SessionRole
	let title: String
}

struct RetroPlan {
	let milestones: [MilestoneWindow]
	let sessions: [SessionEntry]

	init(milestones milestoneTable: String, sessions sessionTable: String) throws {
		milestones = try Self.rows(milestoneTable, columns: 3, name: "milestones.tsv").map {
			guard let start = TimeText.epochSecond($0[1]) else {
				throw RetroFailure(description: "milestones.tsv: bad start \($0[1])")
			}
			return MilestoneWindow(
				name: $0[0], start: start,
				commitRanges: $0[2].split(separator: " ").map(String.init))
		}
		guard !milestones.isEmpty,
			zip(milestones, milestones.dropFirst()).allSatisfy({ $0.start < $1.start })
		else {
			throw RetroFailure(description: "milestones.tsv must list milestones by start time")
		}
		let names = Set(milestones.map(\.name))
		sessions = try Self.rows(sessionTable, columns: 5, name: "sessions.tsv").map {
			guard let role = SessionRole(rawValue: $0[3]) else {
				throw RetroFailure(description: "sessions.tsv: unknown role \($0[3])")
			}
			let placement: Placement = $0[2] == "by-date" ? .byDate : .milestone($0[2])
			if case .milestone(let name) = placement, !names.contains(name) {
				throw RetroFailure(description: "sessions.tsv: unknown milestone \(name)")
			}
			return SessionEntry(
				id: $0[0], created: $0[1], placement: placement, role: role, title: $0[4])
		}.sorted { ($0.created, $0.id) < ($1.created, $1.id) }
	}

	func milestone(at second: Int) -> String {
		(milestones.last { $0.start <= second } ?? milestones[0]).name
	}

	func milestone(of session: SessionEntry, at second: Int) -> String {
		switch session.placement {
		case .milestone(let name): name
		case .byDate: milestone(at: second)
		}
	}

	private static func rows(_ table: String, columns: Int, name: String) throws -> [[String]] {
		let lines = table.split(separator: "\n", omittingEmptySubsequences: true).dropFirst()
		return try lines.map { line in
			let cells = line.split(separator: "\t", omittingEmptySubsequences: false).map(
				String.init)
			guard cells.count == columns else {
				throw RetroFailure(description: "\(name): expected \(columns) columns in \(line)")
			}
			return cells
		}
	}
}
