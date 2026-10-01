import EnduragentCoach
import Foundation

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
	public private(set) var calls: [FakeIntervalsCall]
	public var athleteId: String
	public var athleteName: String
	public var ftp: Int
	public var loadFailure: (any Error)?
	public var writeFailure: (any Error)?

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
		self.calls = []
		self.loadFailure = nil
		self.writeFailure = nil
	}

	public func fetchAthlete() async throws -> AthleteProfile {
		if let loadFailure {
			throw loadFailure
		}
		return AthleteProfile(id: athleteId, name: athleteName, ftp: ftp)
	}

	public func fetchWellness(oldest: CivilDate, newest: CivilDate) async throws -> [WellnessDay] {
		if let loadFailure {
			throw loadFailure
		}
		calls.append(.wellness(oldest: oldest, newest: newest))
		return wellness.filter { $0.date >= oldest && $0.date <= newest }
	}

	public func fetchActivities(oldest: CivilDate, newest: CivilDate) async throws
		-> [ActivitySummary]
	{
		let days = IntervalsPolicy.inclusiveDayCount(from: oldest, to: newest)
		calls.append(.activities(days: days))
		return activities.filter { $0.date >= oldest && $0.date <= newest }
	}

	public func fetchActivity(id: ActivityID) async throws -> JSONValue {
		calls.append(.activity(id))
		return activity
	}

	public func fetchStreams(id: ActivityID) async throws -> JSONValue {
		calls.append(.streams(id))
		return streams
	}

	public func fetchEvent(id: EventID) async throws -> CalendarEvent {
		guard let event = events.first(where: { $0.id == id }) else {
			throw IntervalsError(code: "http", details: "Missing event", status: 404)
		}
		return event
	}

	public func listEvents(oldest: CivilDate, newest: CivilDate) async throws -> [CalendarEvent] {
		calls.append(.events(oldest: oldest, newest: newest))
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
		calls.append(.createEvent(date: draft.date, externalId: draft.externalId.rawValue))
		return CalendarEvent(
			id: EventID(rawValue: 1),
			startDateLocal: "\(draft.date.rawValue)T00:00:00",
			name: draft.name,
			category: "WORKOUT",
			externalId: draft.externalId.rawValue,
			uid: nil,
			tags: draft.tags,
			coachCreated: true
		)
	}

	public func updateEvent(id: EventID, name: String?, description: String?, date: CivilDate?)
		async throws -> CalendarEvent
	{
		if let writeFailure {
			throw writeFailure
		}
		calls.append(.updateEvent(id))
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
		calls.append(.deleteEvent(id))
	}
}
