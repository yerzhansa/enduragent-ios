import Foundation
import Synchronization

final class Turnstile: Sendable {
	private struct State {
		var held = false
		var line: [(UUID, CheckedContinuation<Bool, Never>)] = []
	}

	private let state = Mutex(State())

	var held: Bool { state.withLock { $0.held } }
	var waiting: Bool { state.withLock { !$0.line.isEmpty } }

	func pass<Value, Failure: Error>(
		isolation: isolated (any Actor)? = #isolation,
		_ body: nonisolated(nonsending) () async throws(Failure) -> Value
	) async throws(Failure) -> Value {
		_ = await enter(cancellable: false)
		defer { leave() }
		return try await body()
	}

	func passCancellable<Value>(
		isolation: isolated (any Actor)? = #isolation,
		_ body: nonisolated(nonsending) () async throws -> Value
	) async throws -> Value {
		guard await enter(cancellable: true) else { throw CancellationError() }
		defer { leave() }
		try Task.checkCancellation()
		return try await body()
	}

	private func enter(cancellable: Bool) async -> Bool {
		let id = UUID()
		return await withTaskCancellationHandler {
			await withCheckedContinuation { continuation in
				let entered: Bool? = state.withLock { current in
					if cancellable && Task.isCancelled { return false }
					guard current.held else {
						current.held = true
						return true
					}
					current.line.append((id, continuation))
					return nil
				}
				if let entered { continuation.resume(returning: entered) }
			}
		} onCancel: {
			if cancellable { self.cancel(id) }
		}
	}

	private func cancel(_ id: UUID) {
		let continuation = state.withLock { current -> CheckedContinuation<Bool, Never>? in
			guard let index = current.line.firstIndex(where: { $0.0 == id }) else { return nil }
			return current.line.remove(at: index).1
		}
		continuation?.resume(returning: false)
	}

	private func leave() {
		let continuation = state.withLock { current -> CheckedContinuation<Bool, Never>? in
			guard !current.line.isEmpty else {
				current.held = false
				return nil
			}
			return current.line.removeFirst().1
		}
		continuation?.resume(returning: true)
	}
}
