import EnduragentCoachFixtures
import Foundation

@testable import EnduragentCoach

protocol ForwardingIntervals: TrainingClient {
	var base: FakeIntervalsClient { get }
}

extension ForwardingIntervals {
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

struct HeldReadIntervals: ForwardingIntervals {
	let clock: HeldClock
	let base = FakeIntervalsClient(athleteName: "Ada", ftp: 250)

	func activities(in range: ReadRange) async throws -> ActivityListing {
		do {
			try await clock.sleep(for: .seconds(30))
		} catch is CancellationError {
			throw URLError(.cancelled)
		}
		return try await base.activities(in: range)
	}
}
