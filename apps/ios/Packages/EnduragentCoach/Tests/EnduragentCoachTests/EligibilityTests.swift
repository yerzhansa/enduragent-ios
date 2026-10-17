import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

extension IntervalsRESTClientTests {
	@Suite struct EligibilityTests {
		struct Judged: Sendable, CustomTestStringConvertible {
			let label: String
			let event: CalendarEvent
			let destination: CivilDate?
			let refusal: Ineligibility?

			var testDescription: String { label }
		}

		static let today: CivilDate = "1998-09-08"

		static let judged: [Judged] = [
			Judged(
				label: "coach workout today",
				event: PreparationFixture.workout(1, on: "1998-09-08"),
				destination: nil, refusal: nil),
			Judged(
				label: "coach workout yesterday",
				event: PreparationFixture.workout(1, on: "1998-09-07"), destination: nil,
				refusal: .pastWorkout),
			Judged(
				label: "moved to yesterday", event: PreparationFixture.workout(1, on: "1998-09-09"),
				destination: "1998-09-07", refusal: .pastDate("1998-09-07")),
			Judged(
				label: "moved to today", event: PreparationFixture.workout(1, on: "1998-09-09"),
				destination: "1998-09-08", refusal: nil),
			Judged(
				label: "athlete workout",
				event: PreparationFixture.workout(1, on: "1998-09-09", owned: false),
				destination: nil, refusal: .notCoachCreated),
			Judged(
				label: "coach race",
				event: PreparationFixture.workout(1, on: "1998-09-09", category: "RACE_A"),
				destination: nil, refusal: .notAWorkout),
			Judged(
				label: "coach note",
				event: PreparationFixture.workout(1, on: "1998-09-09", category: "NOTE"),
				destination: nil, refusal: .notAWorkout),
			Judged(
				label: "race from yesterday",
				event: PreparationFixture.workout(
					1, on: "1998-09-07", owned: false, category: "RACE_A"),
				destination: nil, refusal: .notAWorkout),
		]

		@Test(arguments: judged)
		func eachTargetIsJudgedByOneRule(_ judged: Judged) {
			#expect(
				Eligibility.refusal(
					of: judged.event, destination: judged.destination, today: Self.today)
					== judged.refusal)
		}

		@Test func anAddIsRefusedOnlyBeforeToday() {
			#expect(
				Eligibility.refusal(ofAddOn: "1998-09-07", today: Self.today)
					== .pastDate("1998-09-07"))
			#expect(Eligibility.refusal(ofAddOn: "1998-09-08", today: Self.today) == nil)
			#expect(Eligibility.refusal(ofAddOn: "1998-09-09", today: Self.today) == nil)
		}

		@Test(arguments: [("1998-09-08", nil), ("1998-09-07", Ineligibility.pastWorkout)])
		func aPairedActivityChangesNoJudgement(date: String, refusal: Ineligibility?) async throws {
			let client = try IntervalsRESTClientTests().makeClient()
			let event =
				#"{"start_date_local":"\#(date)T00:00:00","name":"Endurance","category":"WORKOUT","moving_time":3600,"tags":["\#(IntervalsPolicy.coachTag)"]"#
			IntervalsURLProtocolStub.handler = { request in
				let path = request.url?.path ?? ""
				if path.hasSuffix("/events/7") {
					return (200, Data(#"\#(event),"id":7,"paired_activity_id":"i501"}"#.utf8))
				}
				if path.hasSuffix("/events/8") {
					return (200, Data(#"\#(event),"id":8}"#.utf8))
				}
				return (200, Data("[]".utf8))
			}
			var outcomes: [Result<ReviewDraft, PreparationRefusal>] = []
			for id in [7, 8] {
				let request = try PreparationFixture.request(
					#"{"kind":"complete","changes":[{"kind":"delete","eventId":\#(id)}]}"#,
					today: Self.today)
				outcomes.append(
					await PreparationFixture.draft(request, reads: client, today: Self.today))
			}
			let expected = refusal.map {
				[
					PreparationRefusal.ineligible(EventID(rawValue: 7), $0),
					.ineligible(EventID(rawValue: 8), $0),
				]
			}
			#expect(outcomes.map(\.refusal) == (expected ?? [nil, nil]))
			#expect(
				outcomes.map { $0.remaining?.count } == (refusal == nil ? [1, 1] : [nil, nil]))
		}
	}
}
