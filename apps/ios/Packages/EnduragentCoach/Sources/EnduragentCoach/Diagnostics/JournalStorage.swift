import Foundation

package protocol JournalStorage: Sendable {
	func read() throws -> Data?
	func append(_ line: Data) throws
	func replace(with lines: Data) throws
	func removeLeftover() throws
}

package struct FileJournalStorage: JournalStorage {
	package let file: URL
	private let next: URL

	package init(directory: URL) {
		file = directory.appending(path: "diagnostics.jsonl")
		next = directory.appending(path: "diagnostics.jsonl.next")
	}

	package func read() throws -> Data? {
		do {
			return try Data(contentsOf: file)
		} catch let error as CocoaError where error.code == .fileReadNoSuchFile {
			return nil
		}
	}

	package func append(_ line: Data) throws {
		let handle: FileHandle
		do {
			handle = try FileHandle(forWritingTo: file)
		} catch let error as CocoaError where error.code == .fileNoSuchFile {
			try makeDirectory()
			try line.write(to: file, options: .withoutOverwriting)
			return
		}
		try handle.seekToEnd()
		try handle.write(contentsOf: line)
		try handle.close()
	}

	package func replace(with lines: Data) throws {
		try makeDirectory()
		try lines.write(to: next)
		_ = try FileManager.default.replaceItemAt(file, withItemAt: next)
	}

	package func removeLeftover() throws {
		do {
			try FileManager.default.removeItem(at: next)
		} catch let error as CocoaError where error.code == .fileNoSuchFile {
			return
		}
	}

	private func makeDirectory() throws {
		try FileManager.default.createDirectory(
			at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
	}
}

package struct JournalRecord: Sendable, Equatable {
	package let stamped: StampedLine
	package let encoded: Data

	package init(_ stamped: StampedLine) throws {
		self.stamped = stamped
		encoded = try stamped.encoded()
	}
}

package enum JournalPrune {
	package static let keptFor: TimeInterval = 14 * 86_400
	package static let byteLimit = 1_048_576
	package static let pruneTarget = 786_432

	package static func kept(_ records: [JournalRecord], now: Date) -> [JournalRecord] {
		let recent = records.filter { now.timeIntervalSince($0.stamped.at) <= keptFor }
		var bytes = recent.reduce(0) { $0 + $1.encoded.count + 1 }
		guard bytes > byteLimit else { return recent }
		var dropped = 0
		while bytes > pruneTarget {
			bytes -= recent[dropped].encoded.count + 1
			dropped += 1
		}
		return Array(recent.dropFirst(dropped))
	}
}

package enum JournalHealth: Sendable, Equatable, Encodable {
	case saving
	case notSaving(since: Date, firstCause: JournalFault)
}

package enum JournalFault: String, Sendable, Codable {
	case unreadable
	case appendFailed
	case rewriteFailed
}
