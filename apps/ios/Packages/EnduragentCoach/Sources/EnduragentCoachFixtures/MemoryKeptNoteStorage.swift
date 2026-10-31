import EnduragentCoach
import Foundation
import Synchronization

package final class MemoryKeptNoteStorage: KeptNoteStorage {
	package struct Save: Sendable, Equatable {
		package let phase: KeptPhase
		package let requestsBefore: Int
	}

	private struct State {
		var kept: KeptNote?
		var saves: [Save] = []
		var failing = false
	}

	private let server: FakeFeedbackServer
	private let state = Mutex(State())

	package init(watching server: FakeFeedbackServer) {
		self.server = server
	}

	package var kept: KeptNote? {
		state.withLock { $0.kept }
	}

	package var saves: [Save] {
		state.withLock { $0.saves }
	}

	package func failSaves() {
		state.withLock { $0.failing = true }
	}

	package func load() throws -> KeptNote? {
		state.withLock { $0.kept }
	}

	package func save(_ kept: KeptNote) throws {
		let requests = server.requestCount
		try state.withLock { state in
			state.saves.append(Save(phase: kept.phase, requestsBefore: requests))
			guard !state.failing else { throw CocoaError(.fileWriteOutOfSpace) }
			state.kept = kept
		}
	}

	package func clear() throws {
		state.withLock { $0.kept = nil }
	}
}
