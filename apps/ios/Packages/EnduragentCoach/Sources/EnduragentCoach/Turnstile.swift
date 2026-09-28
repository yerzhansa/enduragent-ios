import Foundation

final class Turnstile {
	private(set) var held = false
	private var line: [CheckedContinuation<Void, Never>] = []

	func pass<Value, Failure: Error>(
		isolation: isolated (any Actor)? = #isolation,
		_ body: nonisolated(nonsending) () async throws(Failure) -> Value
	) async throws(Failure) -> Value {
		await enter()
		defer { leave() }
		return try await body()
	}

	private func enter(isolation: isolated (any Actor)? = #isolation) async {
		guard held else {
			held = true
			return
		}
		await withCheckedContinuation { line.append($0) }
	}

	private func leave() {
		if line.isEmpty {
			held = false
		} else {
			line.removeFirst().resume()
		}
	}
}
