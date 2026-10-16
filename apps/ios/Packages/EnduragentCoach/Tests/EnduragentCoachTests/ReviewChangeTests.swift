import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

extension IntervalsRESTClientTests {
	@Suite struct ReviewChangeTests {
		static let reviewed = WorkoutSnapshot(
			date: "1998-06-17", name: "Endurance", durationSeconds: 3600,
			description: "Warmup\n- 10m 55%", load: 50, structure: #"{"steps":[{"duration":3600}]}"#
		)

		@Test func eachChangedFieldIsNamedAlone() {
			let reviewed = Self.reviewed
			let changed: [(SnapshotField, WorkoutSnapshot)] = [
				(.date, snapshot(date: "1998-06-18")),
				(.name, snapshot(name: "Endurance ride")),
				(.duration, snapshot(durationSeconds: 5400)),
				(.description, snapshot(description: "Warmup\n- 15m 55%")),
				(.load, snapshot(load: 51)),
				(.structure, snapshot(structure: #"{"steps":[{"duration":5400}]}"#)),
			]
			for (field, current) in changed {
				#expect(reviewed.differences(from: current) == [field])
			}
			#expect(
				reviewed.differences(from: snapshot(durationSeconds: 5400, load: nil))
					== [.duration, .load])
			#expect(reviewed.differences(from: snapshot(name: .some(nil))) == [.name])
			#expect(reviewed.differences(from: reviewed).isEmpty)
		}

		@Test func anEquivalentRepresentationIsNoDifference() {
			let current = snapshot(
				name: "Endurance \n", description: "Warmup\r\n- 10m 55%\n\n  ")
			#expect(Self.reviewed.differences(from: current).isEmpty)
			#expect(current.differences(from: Self.reviewed).isEmpty)
			#expect(Self.reviewed.differences(from: snapshot(name: " Endurance")) == [.name])
		}

		@Test func serverMetadataAndAWholeSecondMovingTimeAreNoDifference() async throws {
			let client = try IntervalsRESTClientTests().makeClient()
			let body = #"""
				[
				{"id":7,"start_date_local":"1998-06-17T00:00:00","name":"Endurance","category":"WORKOUT","moving_time":3600,"icu_training_load":50,"description":"Warmup\n- 10m 55%","workout_doc":{"steps":[{"duration":3600}]}},
				{"id":7,"start_date_local":"1998-06-17T06:30:00","name":"Endurance","category":"WORKOUT","moving_time":3600.0,"icu_training_load":50,"description":"Warmup\n- 10m 55%","workout_doc":{"steps":[{"duration":3600.0}]},"updated":"1998-06-16T21:04:11Z","icon":"bike","color":"#00ff00","tags":["coach"],"uid":"other","external_id":"cycling-coach:other","type":"VirtualRide"}
				]
				"""#
			IntervalsURLProtocolStub.handler = { _ in (200, Data(body.utf8)) }
			let events = try await client.listEvents(
				in: ReadRange(oldest: "1998-06-17", newest: "1998-06-17", today: "1998-06-13"))
			let snapshots = try events.map { (event) throws(IntervalsError) in try event.snapshot }
			#expect(snapshots.count == 2)
			#expect(snapshots.allSatisfy { Self.reviewed.differences(from: $0).isEmpty })
		}

		@Test func aPatchIsAppliedExactlyWhenApplyingItChangesNothing() throws {
			let patch = WorkoutPatch(
				date: "1998-06-18", name: nil, durationSeconds: 5400, description: nil,
				trainingLoad: nil, workoutDocument: nil)
			#expect(patch.isApplied(on: patch.applied(to: Self.reviewed)))
			#expect(!patch.isApplied(on: Self.reviewed))
			#expect(!patch.isApplied(on: snapshot(date: "1998-06-18")))
			let described = WorkoutPatch(
				date: nil, name: nil, durationSeconds: nil, description: "Easy spin",
				trainingLoad: nil, workoutDocument: nil)
			#expect(described.isApplied(on: snapshot(description: "Easy spin", structure: nil)))
			#expect(described.isApplied(on: snapshot(description: "Easy spin \n", structure: nil)))
			#expect(!described.isApplied(on: Self.reviewed))
		}

		@Test func anUpgradedEditIsAppliedByTheSameRuleWithoutAReviewedSnapshot() throws {
			let review = try reviewFixture("workout-review-unconfirmed")
			guard case .waiting(.unconfirmed(let attempt)) = review.stage,
				case .edit(let edit) = attempt.change.action,
				case .upgradedWithoutSnapshot(let event, let date) = edit.target
			else {
				throw UnexpectedReview(detail: "the fixture holds no upgraded edit in flight")
			}
			#expect(event == EventID(rawValue: 103))
			let current = WorkoutSnapshot(
				date: date, name: "Long ride", durationSeconds: 5400, description: nil, load: 80,
				structure: #"{"steps":[{"duration":5400}]}"#)
			#expect(edit.patch.isApplied(on: current))
			let untouched = WorkoutSnapshot(
				date: date, name: "Long ride", durationSeconds: 5400, description: nil, load: 80,
				structure: #"{"steps":[{"duration":3600}]}"#)
			#expect(!edit.patch.isApplied(on: untouched))
		}

		private func snapshot(
			date: CivilDate = "1998-06-17", name: String?? = nil, durationSeconds: Int = 3600,
			description: String = "Warmup\n- 10m 55%", load: Int? = 50,
			structure: String? = #"{"steps":[{"duration":3600}]}"#
		) -> WorkoutSnapshot {
			WorkoutSnapshot(
				date: date, name: name ?? "Endurance", durationSeconds: durationSeconds,
				description: description, load: load, structure: structure)
		}
	}
}
