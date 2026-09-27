import Foundation

struct Admitted: ~Copyable {
	fileprivate init() {}
}

final class Admission {
	private(set) var held = false
	private var waiting: [CheckedContinuation<Void, Never>] = []

	func pass<Value, Failure: Error>(
		isolation: isolated (any Actor)? = #isolation,
		_ body: (borrowing Admitted) async throws(Failure) -> Value
	) async throws(Failure) -> Value {
		await enter()
		defer { leave() }
		return try await body(Admitted())
	}

	private func enter(isolation: isolated (any Actor)? = #isolation) async {
		guard held else {
			held = true
			return
		}
		await withCheckedContinuation { waiting.append($0) }
	}

	private func leave() {
		if waiting.isEmpty {
			held = false
		} else {
			waiting.removeFirst().resume()
		}
	}
}
