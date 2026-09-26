import Foundation

final class Admission {
	private var held = false
	private var waiting: [CheckedContinuation<Void, Never>] = []

	func enter(isolation: isolated (any Actor)? = #isolation) async {
		guard held else {
			held = true
			return
		}
		await withCheckedContinuation { waiting.append($0) }
	}

	func leave() {
		if waiting.isEmpty {
			held = false
		} else {
			waiting.removeFirst().resume()
		}
	}
}
