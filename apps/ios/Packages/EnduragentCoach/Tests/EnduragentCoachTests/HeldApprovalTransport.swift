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

final class HeldApprovalWrites: IntervalsClient, Sendable {
	let base: FakeIntervalsClient
	let clock: HeldClock
	private let holds = Mutex(1)
	let failure: (any Error)?

	init(base: FakeIntervalsClient, clock: HeldClock, failure: (any Error)? = nil) {
		self.base = base
		self.clock = clock
		self.failure = failure
	}

	func fetchAthlete() async throws -> AthleteProfile { try await base.fetchAthlete() }
	func fetchWellness(oldest: CivilDate, newest: CivilDate) async throws -> [WellnessDay] {
		try await base.fetchWellness(oldest: oldest, newest: newest)
	}
	func fetchActivities(oldest: CivilDate, newest: CivilDate) async throws -> [ActivitySummary] {
		try await base.fetchActivities(oldest: oldest, newest: newest)
	}
	func fetchActivity(id: ActivityID) async throws -> JSONValue {
		try await base.fetchActivity(id: id)
	}
	func fetchStreams(id: ActivityID) async throws -> JSONValue {
		try await base.fetchStreams(id: id)
	}
	func fetchEvent(id: EventID) async throws -> CalendarEvent { try await base.fetchEvent(id: id) }
	func listEvents(oldest: CivilDate, newest: CivilDate) async throws -> [CalendarEvent] {
		try await base.listEvents(oldest: oldest, newest: newest)
	}
	func createChatEvent(_ draft: ChatCalendarCreate) async throws -> CalendarEvent {
		let hold = holds.withLock { remaining in
			defer { remaining -= 1 }
			return remaining > 0
		}
		if hold {
			try await clock.sleep(for: .seconds(13))
			if let failure { throw failure }
		}
		return try await base.createChatEvent(draft)
	}

	func updateEvent(id: EventID, name: String?, description: String?, date: CivilDate?)
		async throws -> CalendarEvent
	{
		try await base.updateEvent(id: id, name: name, description: description, date: date)
	}
	func deleteEvent(id: EventID) async throws { try await base.deleteEvent(id: id) }
}
