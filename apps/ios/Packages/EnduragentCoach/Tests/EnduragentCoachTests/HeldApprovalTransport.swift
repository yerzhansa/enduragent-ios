import EnduragentCoachFixtures
import Foundation
import Synchronization
import Testing

@testable import EnduragentCoach

final class HeldApprovalTransport: ModelTransport {
	let base: FakeModelTransport
	let clock: HeldClock
	let hold: @Sendable (Int, CompletionRequest) -> Duration?
	private let counter = ApprovalRequestCounter()
	private let streamedTools = Mutex<[Int: Gate]>([:])

	init(
		base: FakeModelTransport, clock: HeldClock,
		hold: @escaping @Sendable (Int, CompletionRequest) -> Duration?
	) {
		self.base = base
		self.clock = clock
		self.hold = hold
	}

	func waitForToolCall(in request: Int) async throws {
		try await toolGate(for: request).waitUnlessCancelled()
	}

	private func toolGate(for request: Int) -> Gate {
		streamedTools.withLock {
			if let gate = $0[request] { return gate }
			let gate = Gate()
			$0[request] = gate
			return gate
		}
	}

	func stream(_ request: CompletionRequest) -> AsyncThrowingStream<TransportEvent, Error> {
		let index = request.charge == .chatAttempt ? counter.next() : 0
		let pause = hold(index, request)
		let source = base.stream(request)
		let clock = clock
		return AsyncThrowingStream { continuation in
			let task = Task {
				do {
					if let pause { try await clock.sleep(for: pause) }
					for try await event in source {
						continuation.yield(event)
						if case .toolCall = event {
							toolGate(for: index).release()
						}
					}
					continuation.finish()
				} catch {
					continuation.finish(throwing: error)
				}
			}
			continuation.onTermination = { _ in task.cancel() }
		}
	}
}

final class ApprovalRequestCounter: Sendable {
	private let value = Mutex(0)
	func next() -> Int {
		value.withLock {
			$0 += 1
			return $0
		}
	}
}

final class HeldApprovalWrites: TrainingClient, Sendable {
	let base: FakeIntervalsClient
	let clock: HeldClock
	private let holds = Mutex(1)
	let failure: IntervalsWriteAnswer?

	init(base: FakeIntervalsClient, clock: HeldClock, failure: IntervalsWriteAnswer? = nil) {
		self.base = base
		self.clock = clock
		self.failure = failure
	}

	func write(_ write: CalendarWrite) async -> IntervalsWriteAnswer {
		guard case .create = write else { return await base.write(write) }
		let hold = holds.withLock { remaining in
			defer { remaining -= 1 }
			return remaining > 0
		}
		if hold {
			do { try await clock.sleep(for: .seconds(13)) } catch { return .lost(.canceled) }
			if let failure { return failure }
		}
		return await base.write(write)
	}

	func profile() async throws -> AthleteProfile { try await base.profile() }

	func wellness(in range: ReadRange) async throws -> [WellnessDay] {
		try await base.wellness(in: range)
	}

	func activities(in range: ReadRange) async throws -> ActivityListing {
		try await base.activities(in: range)
	}

	func activity(_ id: ActivityID) async throws -> ActivityDetailRead {
		try await base.activity(id)
	}

	func streams(of id: ActivityID, channels: StreamChannels) async throws -> StreamSummary {
		try await base.streams(of: id, channels: channels)
	}

	func fetchEvent(id: EventID) async throws -> CalendarEvent { try await base.fetchEvent(id: id) }

	func listEvents(in range: ReadRange) async throws -> [CalendarEvent] {
		try await base.listEvents(in: range)
	}
}
