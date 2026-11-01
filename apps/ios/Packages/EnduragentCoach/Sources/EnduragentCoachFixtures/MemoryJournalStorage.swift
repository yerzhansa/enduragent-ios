import EnduragentCoach
import Foundation
import Synchronization

package final class MemoryJournalStorage: JournalStorage {
	private struct State {
		var lines: Data?
		var failingWrites = 0
		var unreadable = false
	}

	private let state = Mutex(State())

	package init() {}

	package var contents: Data? {
		state.withLock { $0.lines }
	}

	package func failNextWrites(_ count: Int) {
		state.withLock { $0.failingWrites = count }
	}

	package func failReads() {
		state.withLock { $0.unreadable = true }
	}

	package func read() throws -> Data? {
		try state.withLock { state in
			guard !state.unreadable else { throw CocoaError(.fileReadNoPermission) }
			return state.lines
		}
	}

	package func append(_ line: Data) throws {
		try write { $0 = ($0 ?? Data()) + line }
	}

	package func replace(with lines: Data) throws {
		try write { $0 = lines }
	}

	package func removeLeftover() {}

	package func erase() throws {
		try write { $0 = nil }
	}

	private func write(_ change: (inout Data?) -> Void) throws {
		try state.withLock { state in
			guard state.failingWrites == 0 else {
				state.failingWrites -= 1
				throw CocoaError(.fileWriteOutOfSpace)
			}
			change(&state.lines)
		}
	}
}

extension DiagnosticsLog {
	package convenience init(clock: any Clock) {
		self.init(clock: clock, storage: MemoryJournalStorage())
	}
}
