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

public final class FakeIntervalsClient: IntervalsClient, @unchecked Sendable {
	public var activities: [ActivitySummary]
	public var wellness: [WellnessDay]
	public var activity: JSONValue
	public var streams: JSONValue
	public var events: [CalendarEvent]
	private let recordedCalls = Mutex<[FakeIntervalsCall]>([])
	public var calls: [FakeIntervalsCall] { recordedCalls.withLock { $0 } }
	public var athleteId: String
	public var athleteName: String
	public var ftp: Int
	public var writeFailure: (any Error)?
	private let displayReads = Mutex(FakeIntervalsDisplayReads())
	private let nextActivityReadDelay = Mutex<Duration>(.zero)

	public func delayNextActivityRead(for duration: Duration) {
		nextActivityReadDelay.withLock { $0 = duration }
	}

	public var profileReadCount: Int { displayReads.withLock { $0.profileCount } }
	public var wellnessReadCount: Int { displayReads.withLock { $0.wellnessCount } }

	public func setProfileOutcome(_ result: Result<AthleteProfile, any Error>, once: Bool = false) {
		displayReads.withLock { $0.profile = (result, once) }
	}

	public func setWellnessOutcome(_ result: Result<[WellnessDay], any Error>, once: Bool = false) {
		displayReads.withLock { $0.wellness = (result, once) }
	}

	public func holdNextProfileRead() -> FakeIntervalsReadGate {
		let gate = FakeIntervalsReadGate()
		displayReads.withLock { $0.profileGate = gate }
		return gate
	}

	public func holdNextWellnessRead() -> FakeIntervalsReadGate {
		let gate = FakeIntervalsReadGate()
		displayReads.withLock { $0.wellnessGate = gate }
		return gate
	}
	#if DEBUG
		public var loseCalendarSaveAnswerOnce = false
		public var failCalendarReadOnce = false
	#endif

	public init(athleteName: String, ftp: Int, athleteId: String = "i1001") {
		self.athleteId = athleteId
		self.athleteName = athleteName
		self.ftp = ftp
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

	public func fetchAthlete() async throws -> AthleteProfile {
		let (outcome, gate) = displayReads.withLock {
			$0.profileCount += 1
			let result =
				$0.profile?.result
				?? .success(AthleteProfile(id: athleteId, name: athleteName, ftp: ftp))
			if $0.profile?.once == true { $0.profile = nil }
			let gate = $0.profileGate
			$0.profileGate = nil
			return (result, gate)
		}
		await gate?.enter()
		return try outcome.get()
	}

	public func fetchWellness(oldest: CivilDate, newest: CivilDate) async throws -> [WellnessDay] {
		let (outcome, gate) = displayReads.withLock {
			$0.wellnessCount += 1
			let result = $0.wellness?.result ?? .success(wellness)
			if $0.wellness?.once == true { $0.wellness = nil }
			let gate = $0.wellnessGate
			$0.wellnessGate = nil
			return (result, gate)
		}
		recordedCalls.withLock { $0.append(.wellness(oldest: oldest, newest: newest)) }
		await gate?.enter()
		return try outcome.get().filter { $0.date >= oldest && $0.date <= newest }
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
