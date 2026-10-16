import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

extension IntervalsRESTClientTests {
	@Suite struct WorkoutSnapshotTests {
		@Test func aListRowsSnapshotReadsItsFieldsAndKeepsAnAbsentValueAbsent() async throws {
			let client = try IntervalsRESTClientTests().makeClient()
			let body = #"""
				[
				{"id":1,"start_date_local":"1998-06-14T00:00:00","name":"Endurance","category":"WORKOUT","moving_time":3600,"icu_training_load":52,"description":"Warmup\r\n- 10m 55%","workout_doc":{"steps":[{"text":"spin\r\neasy","duration":3600}],"duration":3600}},
				{"id":2,"start_date_local":"1998-06-15T06:30:00","category":"WORKOUT","moving_time":null,"icu_training_load":null,"workout_doc":null}
				]
				"""#
			IntervalsURLProtocolStub.handler = { _ in (200, Data(body.utf8)) }
			let events = try await client.listEvents(
				in: ReadRange(oldest: "1998-06-14", newest: "1998-06-20", today: "1998-06-13"))
			let snapshots = try events.map { (event) throws(IntervalsError) in try event.snapshot }
			#expect(
				snapshots == [
					WorkoutSnapshot(
						date: "1998-06-14", name: "Endurance", durationSeconds: 3600,
						description: "Warmup\n- 10m 55%", load: 52,
						structure:
							#"{"duration":3600,"steps":[{"duration":3600,"text":"spin\neasy"}]}"#
					),
					WorkoutSnapshot(
						date: "1998-06-15", name: nil, durationSeconds: nil, description: nil,
						load: nil, structure: nil),
				])
		}

		@Test func anEventWithoutACalendarDateHasNoSnapshot() {
			let event = CalendarEvent(
				id: EventID(rawValue: 7), startDateLocal: "soon", name: "Endurance",
				category: "WORKOUT", externalId: nil, uid: nil, tags: [], coachCreated: false)
			#expect(
				throws: IntervalsError(
					code: "invalid_json", details: "calendar event has an invalid date")
			) {
				_ = try event.snapshot
			}
		}
	}
}
