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
							#"{"steps":[{"duration":3600,"text":"spin\neasy"}]}"#
					),
					WorkoutSnapshot(
						date: "1998-06-15", name: nil, durationSeconds: nil, description: nil,
						load: nil, structure: nil),
				])
		}

		@Test(arguments: [
			"workout-review-refreshed", "workout-review-try-again",
			"workout-review-try-again-load-only",
		])
		func aStoredReviewsStructureIsTheSnapshotOfItsOwnStepsAgain(_ fixture: String) throws {
			_ = try reviewFixture(fixture)
			let stored = Self.structures(
				in: try JSONValue.parse(String(decoding: try fixtureData(fixture), as: UTF8.self)))
			#expect(!stored.isEmpty)
			for structure in stored {
				let event = CalendarEvent(
					id: EventID(rawValue: 1), startDateLocal: "1998-07-04T00:00:00", name: nil,
					category: "WORKOUT", externalId: nil, uid: nil, tags: [], coachCreated: true,
					workoutDocument: try JSONValue.parse(structure))
				#expect(try event.snapshot.structure == structure)
			}
		}

		private static func structures(in value: JSONValue) -> [String] {
			switch value {
			case .object(let fields):
				fields.flatMap { key, field in
					key == "structure"
						? field.stringValue.map { [$0] } ?? [] : structures(in: field)
				}
			case .array(let items): items.flatMap(structures)
			case .null, .bool, .number, .string: []
			}
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
