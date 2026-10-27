import Foundation
import Synchronization

package final class Journal: Sendable {
	package let openings: [JournalOpening]
	private let storage: any JournalStorage
	private let clock: any Clock
	private let state: Mutex<JournalState>

	package init(storage: any JournalStorage, clock: any Clock) {
		self.storage = storage
		self.clock = clock
		var opened = JournalState()
		openings = opened.open(storage, now: clock.now)
		state = Mutex(opened)
	}

	package var health: JournalHealth {
		state.withLock { $0.health }
	}

	package func append(_ record: JournalRecord) {
		let now = clock.now
		state.withLock { $0.append(record, to: storage, now: now) }
	}

	package func window(endingAt now: Date) -> [StampedLine] {
		JournalPrune.kept(state.withLock { $0.records }, now: now).map(\.stamped)
	}
}

package enum JournalOpening: Sendable, Equatable {
	case linesDropped(Int)
	case restarted(JournalFault)
}

struct JournalState: Sendable {
	private enum Disk: Sendable {
		case holdsRecords
		case unread
		case behind(since: Date, firstCause: JournalFault)
	}

	private(set) var records: [JournalRecord] = []
	private var bytes = 0
	private var disk = Disk.holdsRecords

	var health: JournalHealth {
		guard case .behind(let since, let firstCause) = disk else { return .saving }
		return .notSaving(since: since, firstCause: firstCause)
	}

	mutating func open(_ storage: any JournalStorage, now: Date) -> [JournalOpening] {
		do {
			try storage.removeLeftover()
		} catch {
			fail(.rewriteFailed, at: now)
		}
		let found: Data?
		do {
			found = try storage.read()
		} catch {
			if case .holdsRecords = disk { disk = .unread }
			return [.restarted(.unreadable)]
		}
		var decoded: [JournalRecord] = []
		var dropped = 0
		for line in (found ?? Data()).split(separator: UInt8(ascii: "\n")) {
			do {
				decoded.append(try JournalRecord(StampedLine(decoding: Data(line))))
			} catch {
				dropped += 1
			}
		}
		keep(decoded, now: now)
		if Self.file(records) != found ?? Data() {
			rewrite(storage, now: now)
		}
		return dropped == 0 ? [] : [.linesDropped(dropped)]
	}

	mutating func append(_ record: JournalRecord, to storage: any JournalStorage, now: Date) {
		records.append(record)
		bytes += record.encoded.count + 1
		guard case .holdsRecords = disk, bytes <= JournalPrune.byteLimit else {
			keep(records, now: now)
			rewrite(storage, now: now)
			return
		}
		do {
			try storage.append(record.encoded + Self.newline)
		} catch {
			fail(.appendFailed, at: now)
		}
	}

	private mutating func keep(_ candidates: [JournalRecord], now: Date) {
		records = JournalPrune.kept(candidates, now: now)
		bytes = records.reduce(0) { $0 + $1.encoded.count + 1 }
	}

	private mutating func rewrite(_ storage: any JournalStorage, now: Date) {
		do {
			try storage.replace(with: Self.file(records))
			disk = .holdsRecords
		} catch {
			fail(.rewriteFailed, at: now)
		}
	}

	private mutating func fail(_ cause: JournalFault, at now: Date) {
		if case .behind = disk { return }
		disk = .behind(since: now, firstCause: cause)
	}

	private static let newline = Data("\n".utf8)

	private static func file(_ records: [JournalRecord]) -> Data {
		records.reduce(into: Data()) { file, record in
			file.append(record.encoded)
			file.append(newline)
		}
	}
}
