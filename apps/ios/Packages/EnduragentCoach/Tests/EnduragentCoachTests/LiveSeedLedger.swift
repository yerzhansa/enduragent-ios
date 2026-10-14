import Foundation

@testable import EnduragentCoach

struct LiveSeedLedger: Sendable {
	static let header = "kind\tkey\tvalue"

	let file: URL
	private(set) var athlete: String?
	private(set) var anchor: CivilDate?
	private(set) var activities: [String: String] = [:]
	private(set) var wellness: [CivilDate: [String]] = [:]

	init(file: URL) throws {
		self.file = file
		guard FileManager.default.fileExists(atPath: file.path) else { return }
		let rows = try String(contentsOf: file, encoding: .utf8).split(separator: "\n").dropFirst()
		for row in rows {
			let cells = row.split(separator: "\t", omittingEmptySubsequences: false).map(
				String.init)
			switch (cells.first, cells.count) {
			case ("athlete", 3):
				athlete = cells[1]
			case ("anchor", 3):
				anchor = try Self.date(cells[1], in: row)
			case ("activity", 3):
				activities[cells[1]] = cells[2]
			case ("wellness", 3):
				wellness[try Self.date(cells[1], in: row)] = cells[2].split(separator: ",").map(
					String.init)
			default:
				throw LiveCheckStop(description: "\(file.path) has a row it cannot read: \(row)")
			}
		}
	}

	var activityIDs: [String] { activities.sorted { $0.key < $1.key }.map(\.value) }

	var summary: String {
		let dates = wellness.keys.sorted()
		let span =
			dates.first.map { "\($0.rawValue) to \(dates.last?.rawValue ?? $0.rawValue)" } ?? "none"
		return
			"athlete \(athlete ?? "none"), anchor \(anchor?.rawValue ?? "none"), \(activities.count) activities, \(wellness.count) wellness days (\(span))"
	}

	mutating func record(athlete id: String) throws {
		try append(["athlete", id, ""])
		athlete = id
	}

	mutating func record(anchor date: CivilDate) throws {
		try append(["anchor", date.rawValue, ""])
		anchor = date
	}

	mutating func record(activity externalID: String, id: String) throws {
		try append(["activity", externalID, id])
		activities[externalID] = id
	}

	mutating func record(wellness date: CivilDate, fields: [String]) throws {
		try append(["wellness", date.rawValue, fields.joined(separator: ",")])
		wellness[date] = fields
	}

	func retire(as name: String) throws {
		try FileManager.default.moveItem(
			at: file, to: file.deletingLastPathComponent().appending(path: name))
	}

	private func append(_ cells: [String]) throws {
		let line = Data((cells.joined(separator: "\t") + "\n").utf8)
		guard FileManager.default.fileExists(atPath: file.path) else {
			try FileManager.default.createDirectory(
				at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
			try (Data((Self.header + "\n").utf8) + line).write(to: file, options: .atomic)
			return
		}
		let handle = try FileHandle(forWritingTo: file)
		do {
			try handle.seekToEnd()
			try handle.write(contentsOf: line)
		} catch {
			try handle.close()
			throw error
		}
		try handle.close()
	}

	private static func date(_ text: String, in row: Substring) throws -> CivilDate {
		guard let date = CivilDate(rawValue: text) else {
			throw LiveCheckStop(description: "The seed ledger has a row with no date: \(row)")
		}
		return date
	}
}
