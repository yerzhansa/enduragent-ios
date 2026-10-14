import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

extension IntervalsRESTClientTests {
	@Suite struct IntervalsNetworkFailureTests {
		static let unreachable =
			#"{"error":"network","details":"intervals.icu could not be reached (URLError -1009)."}"#
		static let failure = IntervalsError(
			code: "network", details: "intervals.icu could not be reached (URLError -1009).")
		let clock = FixedClock(now: "1998-06-13T12:00:00+02:00", timeZone: "Europe/Amsterdam")

		@Test(arguments: [
			(ToolName.intervalsFetchAthlete, "{}", unreachable),
			(.intervalsFetchWellness, #"{"oldest":"1998-06-07"}"#, unreachable),
			(.intervalsFetchActivities, #"{"oldest":"1998-06-07"}"#, unreachable),
			(.intervalsFetchStreams, #"{"activityId":"i1234567"}"#, unreachable),
			(.intervalsListEvents, #"{"oldest":"1998-06-07"}"#, unreachable),
			(
				.intervalsFetchActivity, #"{"activityId":"i1234567"}"#,
				#"{"error":"activity_detail_unavailable","activityId":"i1234567","cause":"network","details":"The detail of activity i1234567 could not be read. The read failed: the activity is not empty or missing, and no other activity stands in for it. Cause: intervals.icu could not be reached (URLError -1009)."}"#
			),
		])
		func everyReadToolShowsAnUnreachableServiceAsANetworkFailure(
			tool: ToolName, arguments: String, answer: String
		) async throws {
			let client = try unreachableClient()
			let outcome = try await makeOfferedTools(
				intervals: client,
				ledger: Ledger(
					log: InMemoryRecordLog(), clock: clock,
					diagnostics: DiagnosticsLog(clock: clock)),
				clock: clock
			).execute(
				name: tool, arguments: try JSONValue.parse(arguments),
				scope: TurnScope(stamp: testStamp(), policy: .npm, ladder: .npm, uptime: .zero)
			).outcome
			guard case .result(let json) = outcome else {
				throw IntervalsError(code: "no_result", details: "\(outcome)")
			}
			let shown = try #require(json.objectFields["data"])
			#expect(shown == (try JSONValue.parse(answer)), "\(canonicalJSON(shown))")
		}

		@Test(arguments: CalendarCall.allCases)
		func everyCalendarCallFailsTheSameWayWhenIntervalsCannotBeReached(call: CalendarCall)
			async throws
		{
			let client = try unreachableClient()
			await #expect(throws: Self.failure) {
				try await call.run(on: client)
			}
		}

		private func unreachableClient() throws -> IntervalsRESTClient {
			let client = try IntervalsRESTClientTests().makeClient(clock: clock)
			IntervalsURLProtocolStub.handler = { _ in throw URLError(.notConnectedToInternet) }
			return client
		}
	}
}

enum CalendarCall: CaseIterable, Sendable {
	case list
	case fetch
	case create
	case update
	case delete

	func run(on client: IntervalsRESTClient) async throws {
		let event = EventID(rawValue: 42)
		switch self {
		case .list:
			_ = try await client.listEvents(
				in: ReadRange(oldest: "1998-06-14", newest: "1998-06-20", today: "1998-06-13"))
		case .fetch:
			_ = try await client.fetchEvent(id: event)
		case .create:
			var draft = try CyclingTools.parseStrengthWorkout(
				try JSONValue.parse(
					#"{"date":"1998-06-14","name":"Core","description":"Planks and bridges."}"#),
				today: "1998-06-13"
			).draft
			draft.writeID = CalendarWriteID()
			_ = try await client.createChatEvent(draft)
		case .update:
			_ = try await client.updateEvent(
				id: event, name: "Endurance", description: nil, date: nil)
		case .delete:
			try await client.deleteEvent(id: event)
		}
	}
}
