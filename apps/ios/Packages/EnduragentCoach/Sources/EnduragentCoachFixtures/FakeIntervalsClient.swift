import EnduragentCoach
import Foundation
import Synchronization

public enum FakeIntervalsCall: Sendable, Equatable {
	case activities(days: Int)
	case wellness(oldest: CivilDate, newest: CivilDate)
	case activity(ActivityID)
	case streams(ActivityID)
	case events(oldest: CivilDate, newest: CivilDate)
	case createEvent(date: CivilDate, externalId: String)
	case updateEvent(EventID)
	case deleteEvent(EventID)
}

public final class FakeIntervalsClient: TrainingReads, IntervalsClient, @unchecked Sendable {
	package var athlete: AthleteProfile
	package var wellness: [WellnessDay]
	public var activities: [ActivitySummary]
	public var activity: JSONValue
	public var streams: JSONValue
	public var events: [CalendarEvent]
	private let recordedCalls = Mutex<[FakeIntervalsCall]>([])
	public var calls: [FakeIntervalsCall] { recordedCalls.withLock { $0 } }
	public var writeFailure: (any Error)?
	private let faults = Mutex(FakeReadFaults())
	private let nextActivityReadDelay = Mutex<Duration>(.zero)

	public func delayNextActivityRead(for duration: Duration) {
		nextActivityReadDelay.withLock { $0 = duration }
	}

	public func fail(_ read: FakeTrainingRead, with error: any Error, once: Bool = false) {
		faults.withLock { $0.fail(read, with: error, once: once) }
	}

	public func restore(_ read: FakeTrainingRead) {
		faults.withLock { $0.restore(read) }
	}

	public func hold(_ read: FakeTrainingRead) -> FakeIntervalsReadGate {
		faults.withLock { $0.hold(read) }
	}

	public func count(of read: FakeTrainingRead) -> Int {
		faults.withLock { $0.count(of: read) }
	}
	#if DEBUG
		public var loseCalendarSaveAnswerOnce = false
		public var failCalendarReadOnce = false
	#endif

	package init(athlete: AthleteProfile) {
		self.athlete = athlete
		self.activities = []
		self.wellness = []
		self.activity = .object([:])
		self.streams = .object([
			"sampleCount": .number(0),
			"channels": .object([:]),
		])
		self.events = []
		self.writeFailure = nil
	}

	package func profile() async throws -> AthleteProfile {
		try await begin(.profile)
		return athlete
	}

	package func wellness(in range: ReadRange) async throws -> [WellnessDay] {
		recordedCalls.withLock {
			$0.append(.wellness(oldest: range.oldest, newest: range.newest))
		}
		try await begin(.wellness)
		return wellness.filter { range.contains($0.date) }
	}

	private func begin(_ read: FakeTrainingRead) async throws {
		let (failure, gate) = faults.withLock { $0.begin(read) }
		try await gate?.enter()
		if let failure { throw failure }
	}

	public func fetchActivities(oldest: CivilDate, newest: CivilDate) async throws
		-> [ActivitySummary]
	{
		let days = IntervalsPolicy.inclusiveDayCount(from: oldest, to: newest)
		recordedCalls.withLock { $0.append(.activities(days: days)) }
		let delay = nextActivityReadDelay.withLock { pending in
			defer { pending = .zero }
			return pending
		}
		if delay > .zero { try await Task.sleep(for: delay) }
		return activities.filter { $0.date >= oldest && $0.date <= newest }
	}

	public func fetchActivity(id: ActivityID) async throws -> JSONValue {
		recordedCalls.withLock { $0.append(.activity(id)) }
		return activity
	}

	public func fetchStreams(id: ActivityID) async throws -> JSONValue {
		recordedCalls.withLock { $0.append(.streams(id)) }
		return streams
	}

	public func fetchEvent(id: EventID) async throws -> CalendarEvent {
		#if DEBUG
			try consumeCalendarReadFault()
		#endif
		guard let event = events.first(where: { $0.id == id }) else {
			throw IntervalsError(code: "http", details: "Missing event", status: 404)
		}
		return event
	}

	public func listEvents(oldest: CivilDate, newest: CivilDate) async throws -> [CalendarEvent] {
		recordedCalls.withLock { $0.append(.events(oldest: oldest, newest: newest)) }
		#if DEBUG
			try consumeCalendarReadFault()
		#endif
		return events.filter { event in
			guard let date = CivilDate(rawValue: String(event.startDateLocal.prefix(10))) else {
				return false
			}
			return date >= oldest && date <= newest
		}
	}

	public func createChatEvent(_ draft: ChatCalendarCreate) async throws -> CalendarEvent {
		if let writeFailure {
			throw writeFailure
		}
		recordedCalls.withLock {
			$0.append(.createEvent(date: draft.date, externalId: draft.externalId.rawValue))
		}
		let previous = draft.writeID.flatMap { identity in
			events.first { $0.uid == identity.uid }
		}
		let event = CalendarEvent(
			description: draft.description, type: draft.type.rawValue,
			id: previous?.id ?? EventID(rawValue: (events.map(\.id.rawValue).max() ?? 0) + 1),
			startDateLocal: "\(draft.date.rawValue)T00:00:00",
			name: draft.name,
			category: "WORKOUT",
			externalId: draft.writeID?.externalID ?? draft.externalId.rawValue,
			uid: draft.writeID?.uid,
			tags: draft.tags,
			coachCreated: true
		)
		if let index = events.firstIndex(where: { $0.id == event.id }) {
			events[index] = event
		} else {
			events.append(event)
		}
		#if DEBUG
			if loseCalendarSaveAnswerOnce {
				loseCalendarSaveAnswerOnce = false
				throw URLError(.timedOut)
			}
		#endif
		return event
	}

	#if DEBUG
		private func consumeCalendarReadFault() throws {
			if failCalendarReadOnce {
				failCalendarReadOnce = false
				throw URLError(.notConnectedToInternet)
			}
		}
	#endif

	public func updateEvent(id: EventID, name: String?, description: String?, date: CivilDate?)
		async throws -> CalendarEvent
	{
		if let writeFailure {
			throw writeFailure
		}
		recordedCalls.withLock { $0.append(.updateEvent(id)) }
		return CalendarEvent(
			id: id,
			startDateLocal: "\(date?.rawValue ?? "1998-06-14")T00:00:00",
			name: name ?? "",
			category: "WORKOUT",
			externalId: nil,
			uid: nil,
			tags: [IntervalsPolicy.coachTag],
			coachCreated: true
		)
	}

	public func deleteEvent(id: EventID) async throws {
		if let writeFailure {
			throw writeFailure
		}
		recordedCalls.withLock { $0.append(.deleteEvent(id)) }
	}
}
