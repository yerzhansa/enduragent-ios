public struct UnconnectedIntervalsClient: IntervalsClient, Sendable {
	public static let error = IntervalsError(
		code: "not_connected",
		details:
			"intervals.icu is not connected. The athlete skipped adding an API key, so training data is unavailable."
	)

	public init() {}

	public func fetchAthlete() async throws -> AthleteProfile { throw Self.error }
	public func fetchWellness(oldest: CivilDate, newest: CivilDate) async throws -> [WellnessDay] {
		throw Self.error
	}
	public func fetchActivities(oldest: CivilDate, newest: CivilDate) async throws
		-> [ActivitySummary]
	{ throw Self.error }
	public func fetchActivity(id: ActivityID) async throws -> JSONValue { throw Self.error }
	public func fetchStreams(id: ActivityID) async throws -> JSONValue { throw Self.error }
	public func listEvents(oldest: CivilDate, newest: CivilDate) async throws -> [CalendarEvent] {
		throw Self.error
	}
	public func createChatEvent(_ draft: ChatCalendarCreate) async throws -> CalendarEvent {
		throw Self.error
	}
	public func createOrUpdatePlanEvent(_ draft: PlanMirrorCreate) async throws -> CalendarEvent {
		throw Self.error
	}
	public func updateEvent(id: EventID, name: String?, description: String?, date: CivilDate?)
		async throws -> CalendarEvent
	{
		throw Self.error
	}
	public func deleteEvent(id: EventID) async throws { throw Self.error }
}
