import Foundation

final class Interruption {
	private(set) var cause: InterruptionCause?
	private var joined: [CheckedContinuation<Void, Never>] = []

	func begin(_ cause: InterruptionCause) {
		self.cause = cause
	}

	func join(isolation: isolated (any Actor)? = #isolation) async {
		await withCheckedContinuation { joined.append($0) }
	}

	func end() {
		cause = nil
		while let waiting = joined.popLast() {
			waiting.resume()
		}
	}
}
