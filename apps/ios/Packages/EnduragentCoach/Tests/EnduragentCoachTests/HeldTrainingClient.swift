import EnduragentCoachFixtures
import Foundation

@testable import EnduragentCoach

struct GatedProfileIntervals: IntervalsClient {
	let base: FakeIntervalsClient
	let gate: Gate

	func fetchAthlete() async throws -> AthleteProfile {
		await gate.wait()
		return try await base.fetchAthlete()
	}
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
		try await base.createChatEvent(draft)
	}
	func updateEvent(id: EventID, name: String?, description: String?, date: CivilDate?)
		async throws -> CalendarEvent
	{
		try await base.updateEvent(id: id, name: name, description: description, date: date)
	}
	func deleteEvent(id: EventID) async throws { try await base.deleteEvent(id: id) }
}
