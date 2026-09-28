import EnduragentCoach
import Foundation

struct SlowTrainingClient: IntervalsClient {
	let inner = FakeIntervalsClient(athleteName: "Ada", ftp: 250)
	let reads = SlowTrainingReads()

	func fetchAthlete() async throws -> AthleteProfile {
		try await reads.recordAndDelay(.athlete)
		return try await inner.fetchAthlete()
	}

	func fetchWellness(oldest: CivilDate, newest: CivilDate) async throws -> [WellnessDay] {
		try await reads.recordAndDelay(.wellness)
		return try await inner.fetchWellness(oldest: oldest, newest: newest)
	}

	func fetchActivities(oldest: CivilDate, newest: CivilDate) async throws -> [ActivitySummary] {
		try await inner.fetchActivities(oldest: oldest, newest: newest)
	}

	func fetchActivity(id: ActivityID) async throws -> JSONValue {
		try await inner.fetchActivity(id: id)
	}

	func fetchStreams(id: ActivityID) async throws -> JSONValue {
		try await inner.fetchStreams(id: id)
	}

	func listEvents(oldest: CivilDate, newest: CivilDate) async throws -> [CalendarEvent] {
		try await inner.listEvents(oldest: oldest, newest: newest)
	}

	func createChatEvent(_ draft: ChatCalendarCreate) async throws -> CalendarEvent {
		try await inner.createChatEvent(draft)
	}

	func createOrUpdatePlanEvent(_ draft: PlanMirrorCreate) async throws -> CalendarEvent {
		try await inner.createOrUpdatePlanEvent(draft)
	}

	func updateEvent(id: EventID, name: String?, description: String?, date: CivilDate?)
		async throws -> CalendarEvent
	{
		try await inner.updateEvent(id: id, name: name, description: description, date: date)
	}

	func deleteEvent(id: EventID) async throws {
		try await inner.deleteEvent(id: id)
	}
}

actor SlowTrainingReads {
	enum Call {
		case athlete
		case wellness
	}

	private(set) var calls: [Call] = []

	func recordAndDelay(_ call: Call) async throws {
		calls.append(call)
		try await Task.sleep(for: .milliseconds(100))
	}
}
