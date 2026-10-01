import Foundation
import Synchronization
import Testing

@testable import EnduragentCoach

@Suite struct GateTests {
	@Test func releaseBeforeParkingStillCompletes() async throws {
		let store = HeldAppendLog(inner: InMemoryRecordLog(), holding: "userMessage", occurrence: 1)
		store.release()
		let completed = Mutex(false)
		let append = Task {
			try await seed(
				store,
				[
					storedRecord(
						device: store.deviceId, wall: 1,
						body: .synced(sampleUser(chatId: .main, text: "Hello")))
				])
			completed.withLock { $0 = true }
		}
		let deadline = ContinuousClock.now + .seconds(1)
		while !completed.withLock({ $0 }), ContinuousClock.now < deadline {
			await Task.yield()
		}
		#expect(completed.withLock { $0 })
		store.release()
		try await append.value
	}
	@Test func cancellingOneWaiterKeepsTheOtherParked() async throws {
		let gate = Gate()
		let completed = Mutex(false)
		let cancelled = Task { try await gate.waitUnlessCancelled() }
		await gate.waitUntilParked()
		let remaining = Task {
			await gate.wait()
			completed.withLock { $0 = true }
		}
		await gate.waitUntilParked()
		cancelled.cancel()
		await #expect(throws: CancellationError.self) { try await cancelled.value }
		#expect(!completed.withLock { $0 })
		gate.release()
		await remaining.value
		#expect(completed.withLock { $0 })
	}

}
