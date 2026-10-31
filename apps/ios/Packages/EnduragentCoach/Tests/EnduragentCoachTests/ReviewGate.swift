import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

actor ReviewGate {
	private let waitLimit: TestWaitLimit
	private var armed = false
	private var gate = Gate()

	init(within waitLimit: TestWaitLimit = .hangGuard) {
		self.waitLimit = waitLimit
	}

	func arm() {
		armed = true
		gate = Gate()
	}
	func pass() async throws {
		guard armed else { return }
		armed = false
		let gate = gate
		let released: Void? = try await beforeDeadline(within: waitLimit) {
			try await gate.waitUnlessCancelled()
		}
		guard released != nil else { throw TestWaitDeadlineExceeded() }
	}
	func release() { gate.release() }
	func waitUntilEntered() async throws -> Bool {
		let gate = gate
		return try await beforeDeadline(within: waitLimit) {
			await gate.waitUntilParked()
		} != nil
	}
}
