import Foundation
import Testing

@Suite struct DeadlineWaitTests {
	@Test func completedEventReturnsItsValue() async throws {
		let gate = Gate()
		gate.release()
		let value = try await beforeDeadline(within: .seconds(5)) {
			try await gate.waitUnlessCancelled()
			return "arrived"
		}
		#expect(value == "arrived")
	}

	@Test func missingEventCancelsItsWaitAtTheDeadline() async throws {
		let gate = Gate()
		let value = try await beforeDeadline(within: .zero) {
			try await gate.waitUnlessCancelled()
		}
		#expect(value == nil)
	}

	@Test func cancellingABoundedWaitCancelsItsParkedEvent() async throws {
		let gate = Gate()
		let waiting = Task {
			try await beforeDeadline(within: .seconds(5)) {
				try await gate.waitUnlessCancelled()
			}
		}
		defer { waiting.cancel() }
		try #require(
			try await beforeDeadline(within: .seconds(5)) {
				await gate.waitUntilParked()
			} != nil,
			"Event wait did not park within five seconds")
		waiting.cancel()
		await #expect(throws: CancellationError.self) { try await waiting.value }
	}
}
