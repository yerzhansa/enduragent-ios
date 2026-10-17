import EnduragentCoach
import Foundation
import Synchronization

public enum FakeIntervalsCall: Sendable, Equatable {
	case profile
	case activities(oldest: CivilDate, newest: CivilDate)
	case wellness(oldest: CivilDate, newest: CivilDate)
	case activity(ActivityID)
	case streams(ActivityID, channels: [String])
	case events(oldest: CivilDate, newest: CivilDate)
	case createEvent(date: CivilDate, externalId: String)
	case updateEvent(EventID)
	case deleteEvent(EventID)

	public var isCalendarCall: Bool { read == nil }

	var read: FakeTrainingRead? {
		switch self {
		case .profile: .profile
		case .wellness: .wellness
		case .activities: .activities
		case .activity: .activity
		case .streams: .streams
		case .events, .createEvent, .updateEvent, .deleteEvent: nil
		}
	}
}

public final class FakeIntervalsClient: TrainingReads, IntervalsClient, @unchecked Sendable {
	package var athlete: AthleteProfile
	package var wellness: [WellnessDay]
	package var activities: [Activity]
	package var stravaHidden: [CivilDate]
	package var unreadable: [CivilDate]
	package var details: [ActivityID: ActivityDetailRead]
	package var streams: [ActivityID: [StreamSamples]]
	package var streamGaps: [ActivityID: [String: ChannelGap]]
	public var events: [CalendarEvent]
	package var unreadableEvents: Set<EventID> = []
	package var unreadableLists: [ReadRange] = []
	private let recordedCalls = Mutex<[FakeIntervalsCall]>([])
	public var calls: [FakeIntervalsCall] { recordedCalls.withLock { $0 } }
	public var writeFailure: IntervalsWriteAnswer?
	private let faults = Mutex(FakeReadFaults())

	public func fail(_ read: FakeTrainingRead, with error: any Error, once: Bool = false) {
		faults.withLock { $0.fail(read, with: error, once: once) }
	}

	public func restore(_ read: FakeTrainingRead) {
		faults.withLock { $0.restore(read) }
	}

	public func hold(_ read: FakeTrainingRead) -> FakeIntervalsReadGate {
		faults.withLock { $0.hold(read) }
	}

	public func delay(_ read: FakeTrainingRead, by duration: Duration) {
		faults.withLock { $0.delay(read, by: duration) }
	}

	public func count(of read: FakeTrainingRead) -> Int {
		calls.filter { $0.read == read }.count
	}
	#if DEBUG
		public var loseCalendarSaveAnswerOnce = false
		public var failCalendarReadOnce = false
	#endif

	package init(athlete: AthleteProfile) {
		self.athlete = athlete
		self.activities = []
		self.stravaHidden = []
		self.unreadable = []
		self.wellness = []
		self.details = [:]
		self.streams = [:]
		self.streamGaps = [:]
		self.events = []
		self.writeFailure = nil
	}

	package func profile() async throws -> AthleteProfile {
		recordedCalls.withLock { $0.append(.profile) }
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

	package func activities(in range: ReadRange) async throws -> ActivityListing {
		recordedCalls.withLock {
			$0.append(.activities(oldest: range.oldest, newest: range.newest))
		}
		try await begin(.activities)
		let listed = activities.filter { range.contains($0.start.date) }
		return ActivityListing(
			range: range,
			rows: listed.map(ActivityRow.activity)
				+ stravaHidden.filter(range.contains).map { _ in .hiddenByStrava }
				+ unreadable.filter(range.contains).map { _ in .unreadable })
	}

	private func begin(_ read: FakeTrainingRead) async throws {
		let (failure, gate, delay) = faults.withLock { $0.begin(read) }
		do {
			try await gate?.enter()
			if let delay { try await Task.sleep(for: delay) }
		} catch let cancelled as CancellationError {
			throw failure ?? cancelled
		}
		if let failure { throw failure }
	}

	package func activity(_ id: ActivityID) async throws -> ActivityDetailRead {
		recordedCalls.withLock { $0.append(.activity(id)) }
		try await begin(.activity)
		switch details[id] {
		case .found(let detail)?:
			return .found(
				try ActivityDetail(
					asked: id, activity: detail.activity, extras: detail.extras, laps: detail.laps))
		case let answer?:
			return answer
		case nil:
			guard let stored = activities.first(where: { $0.id == id }) else { return .notFound }
			return .found(
				try ActivityDetail(
					asked: id, activity: stored, extras: ActivityDetailExtras(),
					laps: .notSupplied))
		}
	}

	package func streams(of id: ActivityID, channels: StreamChannels) async throws
		-> StreamSummary
	{
		recordedCalls.withLock { $0.append(.streams(id, channels: channels.names)) }
		try await begin(.streams)
		return StreamSummary(
			summarizing: streams[id] ?? [], asked: channels, reported: streamGaps[id] ?? [:])
	}

	public func fetchEvent(id: EventID) async throws -> CalendarEvent {
		#if DEBUG
			try consumeCalendarReadFault()
		#endif
		if unreadableEvents.contains(id) {
			throw IntervalsError.unreachable(URLError(.timedOut))
		}
		guard let event = events.first(where: { $0.id == id }) else {
			throw IntervalsError(code: "http", details: "Missing event", status: 404)
		}
		return event
	}

	package func listEvents(in range: ReadRange) async throws -> [CalendarEvent] {
		recordedCalls.withLock { $0.append(.events(oldest: range.oldest, newest: range.newest)) }
		#if DEBUG
			try consumeCalendarReadFault()
		#endif
		if unreadableLists.contains(range) {
			throw IntervalsError.unreachable(URLError(.timedOut))
		}
		return events.filter { event in
			CivilDate(rawValue: String(event.startDateLocal.prefix(10))).map(range.contains)
				?? false
		}
	}

	package func write(_ write: CalendarWrite) async -> IntervalsWriteAnswer {
		if let writeFailure {
			return writeFailure
		}
		switch write {
		case .create(let payload, let identity):
			return create(payload, identity: identity)
		case .update(let id, let patch):
			recordedCalls.withLock { $0.append(.updateEvent(id)) }
			return .saved(
				CalendarEvent(
					description: patch.description,
					id: id,
					startDateLocal: "\(patch.date?.rawValue ?? "1998-06-14")T00:00:00",
					name: patch.name ?? "",
					category: "WORKOUT",
					externalId: nil,
					uid: nil,
					tags: [IntervalsPolicy.coachTag],
					coachCreated: true
				))
		case .delete(let id):
			recordedCalls.withLock { $0.append(.deleteEvent(id)) }
			return .saved(nil)
		}
	}

	private func create(_ payload: CalendarPayload, identity: CalendarWriteID)
		-> IntervalsWriteAnswer
	{
		recordedCalls.withLock {
			$0.append(.createEvent(date: payload.date, externalId: identity.externalID))
		}
		let previous = events.first { $0.externalId == identity.externalID }
		let event = CalendarEvent(
			description: payload.description, type: payload.type.rawValue,
			id: previous?.id ?? EventID(rawValue: (events.map(\.id.rawValue).max() ?? 0) + 1),
			startDateLocal: "\(payload.date.rawValue)T00:00:00",
			name: payload.name,
			category: "WORKOUT",
			externalId: identity.externalID,
			uid: identity.uid,
			tags: [IntervalsPolicy.coachTag],
			coachCreated: true,
			movingTime: payload.movingTime,
			trainingLoad: payload.trainingLoad
		)
		if let index = events.firstIndex(where: { $0.id == event.id }) {
			events[index] = event
		} else {
			events.append(event)
		}
		#if DEBUG
			if loseCalendarSaveAnswerOnce {
				loseCalendarSaveAnswerOnce = false
				return .lost(.transport)
			}
		#endif
		return .saved(event)
	}

	#if DEBUG
		private func consumeCalendarReadFault() throws {
			if failCalendarReadOnce {
				failCalendarReadOnce = false
				throw IntervalsError.unreachable(URLError(.notConnectedToInternet))
			}
		}
	#endif
}
