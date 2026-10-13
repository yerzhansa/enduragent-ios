package struct UnconnectedIntervalsClient: TrainingClient, Sendable {
	package static let error = IntervalsError(
		code: "not_connected",
		details:
			"intervals.icu is not connected. The athlete skipped adding an API key, so training data is unavailable."
	)

	package init() {}

	package func profile() async throws -> AthleteProfile { throw Self.error }
	package func wellness(in range: ReadRange) async throws -> [WellnessDay] { throw Self.error }
	package func fetchActivities(oldest: CivilDate, newest: CivilDate) async throws
		-> [ActivitySummary]
	{ throw Self.error }
	package func fetchActivity(id: ActivityID) async throws -> JSONValue { throw Self.error }
	package func fetchStreams(id: ActivityID) async throws -> JSONValue { throw Self.error }
	package func fetchEvent(id: EventID) async throws -> CalendarEvent { throw Self.error }
	package func listEvents(oldest: CivilDate, newest: CivilDate) async throws -> [CalendarEvent] {
		throw Self.error
	}
	package func createChatEvent(_ draft: ChatCalendarCreate) async throws -> CalendarEvent {
		throw Self.error
	}
	package func updateEvent(id: EventID, name: String?, description: String?, date: CivilDate?)
		async throws -> CalendarEvent
	{
		throw Self.error
	}
	package func deleteEvent(id: EventID) async throws { throw Self.error }
}
