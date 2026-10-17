import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

@Suite struct PreparationTests {
	let today: CivilDate = "1998-09-08"
	let intervals = FakeIntervalsClient(athleteName: "Ada", ftp: 250)

	@Test func aMixedRequestDraftsEachChangeExactlyAsItsBuilderMakesIt() async throws {
		let edited = PreparationFixture.workout(101, on: "1998-09-10")
		intervals.events = [edited, PreparationFixture.workout(102, on: "1998-09-10")]
		let ride = try JSONValue.parse(PreparationFixture.ride(on: "1998-09-09"))
		let strength = try JSONValue.parse(PreparationFixture.strength(on: "1998-09-09"))
		let patch = try JSONValue.parse(#"{"durationSeconds":4500,"name":"Longer endurance"}"#)
		let request = try PreparationFixture.request(
			#"{"kind":"complete","changes":[\#(ride.canonicalDigestInput()),\#(strength.canonicalDigestInput()),{"kind":"edit","eventId":101,"patch":\#(patch.canonicalDigestInput())},{"kind":"delete","eventId":102}]}"#,
			today: today)

		let remaining = try #require(
			await PreparationFixture.draft(request, reads: intervals, today: today).remaining)

		#expect(remaining.map(\.reuse) == [nil, nil, nil, nil])
		guard remaining.count == 4, case .add(let first) = remaining[0].action,
			case .add(let second) = remaining[1].action
		else {
			Issue.record("the draft is not two adds followed by an edit and a delete")
			return
		}
		#expect(first.payload == (try CalendarPayload.ride(ride, today: today)))
		#expect(second.payload == (try CalendarPayload.strength(strength, today: today)))
		#expect(first.identity != second.identity)
		#expect(
			remaining[2].action
				== .edit(
					EditedWorkout(
						target: .reviewed(EventID(rawValue: 101), try edited.snapshot),
						patch: try WorkoutPatch.parse(patch, today: today))))
		#expect(
			remaining[3].action
				== .delete(
					DeletedWorkout(
						target: .reviewed(
							EventID(rawValue: 102), try intervals.events[1].snapshot))))
		#expect(intervals.calls.allSatisfy { !$0.isWrite })
	}

	@Test(arguments: [
		#"[{"kind":"edit","eventId":101,"patch":{"name":"Tempo"}},{"kind":"delete","eventId":101}]"#,
		#"[{"kind":"edit","eventId":101,"patch":{"name":"Tempo"}},{"kind":"edit","eventId":101,"patch":{"durationSeconds":4500}}]"#,
	])
	func twoActionsOnOneWorkoutAreRefusedWithNoDraft(_ changes: String) async throws {
		intervals.events = [PreparationFixture.workout(101, on: "1998-09-10")]
		let request = try PreparationFixture.request(
			#"{"kind":"complete","changes":\#(changes)}"#, today: today)

		let drafted = await PreparationFixture.draft(request, reads: intervals, today: today)

		#expect(drafted.refusal == .twoActionsOnOneWorkout(EventID(rawValue: 101)))
		#expect(intervals.calls.isEmpty)
	}

	@Test func keptWorkoutsAreTheUntargetedWorkoutsOfEachAffectedDate() async throws {
		intervals.events = [
			PreparationFixture.workout(301, on: "1998-09-09", name: "Group ride", minutes: 120),
			PreparationFixture.workout(
				302, on: "1998-09-09", name: nil, owned: false, minutes: nil),
			PreparationFixture.workout(
				303, on: "1998-09-09", name: "Local race", category: "RACE_A"),
			PreparationFixture.workout(304, on: "1998-09-09", name: "Travel", category: "NOTE"),
			PreparationFixture.workout(101, on: "1998-09-10", name: "Moved ride"),
			PreparationFixture.workout(305, on: "1998-09-10", name: "Left behind"),
			PreparationFixture.workout(102, on: "1998-09-11", name: "Deleted ride"),
			PreparationFixture.workout(306, on: "1998-09-11", name: "Easy spin", minutes: 45),
			PreparationFixture.workout(307, on: "1998-09-12", name: "Long ride", minutes: 180),
		]
		let request = try PreparationFixture.request(
			#"{"kind":"complete","changes":[\#(PreparationFixture.ride(on: "1998-09-09")),{"kind":"edit","eventId":101,"patch":{"date":"1998-09-12"}},{"kind":"delete","eventId":102}]}"#,
			today: today)

		let drafted = await PreparationFixture.draft(request, reads: intervals, today: today)

		#expect(
			drafted.kept == [
				KeptWorkout(name: "Group ride", date: "1998-09-09", durationMinutes: 120),
				KeptWorkout(name: nil, date: "1998-09-09", durationMinutes: nil),
				KeptWorkout(name: "Long ride", date: "1998-09-12", durationMinutes: 180),
				KeptWorkout(name: "Easy spin", date: "1998-09-11", durationMinutes: 45),
			])
		#expect(
			intervals.calls == [
				.events(oldest: "1998-09-09", newest: "1998-09-09"),
				.events(oldest: "1998-09-12", newest: "1998-09-12"),
				.events(oldest: "1998-09-11", newest: "1998-09-11"),
			])
	}

	@Test func anUnreadableTargetRefusesBeforeAnyOtherRead() async throws {
		intervals.events = [PreparationFixture.workout(101, on: "1998-09-10")]
		let request = try PreparationFixture.request(
			#"{"kind":"complete","changes":[{"kind":"delete","eventId":101},{"kind":"edit","eventId":105,"patch":{"name":"Tempo"}}]}"#,
			today: today)

		let drafted = await PreparationFixture.draft(request, reads: intervals, today: today)

		#expect(drafted.refusal == .targetUnreadable(EventID(rawValue: 105)))
		#expect(intervals.calls.isEmpty)
	}

	@Test func anUnreadableDayOfKeptWorkoutsRefusesTheDraft() async throws {
		intervals.failCalendarReadOnce = true
		let request = try PreparationFixture.request(
			#"{"kind":"complete","changes":[\#(PreparationFixture.ride(on: "1998-09-09"))]}"#,
			today: today)

		let drafted = await PreparationFixture.draft(request, reads: intervals, today: today)

		#expect(drafted.refusal == .keptUnreadable("1998-09-09"))
	}

	@Test func theDraftJudgesEachAddDateAndDestinationAgainstItsOwnToday() async throws {
		intervals.events = [PreparationFixture.workout(101, on: "1998-09-10")]
		let add = try PreparationFixture.request(
			#"{"kind":"complete","changes":[\#(PreparationFixture.strength(on: "1998-09-08"))]}"#,
			today: today)
		let move = try PreparationFixture.request(
			#"{"kind":"complete","changes":[{"kind":"edit","eventId":101,"patch":{"date":"1998-09-09"}}]}"#,
			today: today)
		let later: CivilDate = "1998-09-10"

		#expect(
			await PreparationFixture.draft(add, reads: intervals, today: later).refusal
				== .pastDate("1998-09-08"))
		#expect(
			await PreparationFixture.draft(move, reads: intervals, today: later).refusal
				== .ineligible(EventID(rawValue: 101), .pastDate("1998-09-09")))
		#expect(
			await PreparationFixture.draft(move, reads: intervals, today: today).remaining?.count
				== 1)
	}

	@Test(arguments: [ReviewStage.sending, .checking, .sendingLast])
	func aRunningReviewRefusesEveryPreparation(_ stage: ReviewStage) async throws {
		let head = try ReviewStages()[stage]
		let request = try PreparationFixture.request(
			#"{"kind":"complete","changes":[\#(PreparationFixture.ride(on: "1998-09-09"))]}"#,
			today: today)

		let drafted = await PreparationFixture.draft(
			request, head: head, reads: intervals, today: today)

		#expect(drafted.refusal == .reviewRunning)
		#expect(intervals.calls.isEmpty)
	}

	@Test(arguments: [ReviewStage.unconfirmed, .unconfirmedUpgraded])
	func anUnconfirmedChangeRefusesEveryPreparation(_ stage: ReviewStage) async throws {
		let head = try ReviewStages()[stage]
		let request = try PreparationFixture.request(
			#"{"kind":"incomplete","reason":"No safe slot this week"}"#, today: today)

		let drafted = await PreparationFixture.draft(
			request, head: head, reads: intervals, today: today)

		#expect(drafted.refusal == .reviewUnconfirmed)
	}

	@Test(arguments: [ReviewStage.completed, .canceled])
	func aFinishedReviewLeavesACompleteSetFree(_ stage: ReviewStage) async throws {
		let head = try ReviewStages()[stage]
		let request = try PreparationFixture.request(
			#"{"kind":"complete","changes":[\#(PreparationFixture.ride(on: "1998-09-09"))]}"#,
			today: today)

		let drafted = await PreparationFixture.draft(
			request, head: head, reads: intervals, today: today)

		#expect(drafted.remaining?.count == 1)
		#expect(try #require(drafted.draft).base == nil)
	}

	@Test func aWaitingReviewTurnsACompleteSetAway() async throws {
		let head = try ReviewStages()[.approval]
		let request = try PreparationFixture.request(
			#"{"kind":"complete","changes":[\#(PreparationFixture.ride(on: "1998-09-09"))]}"#,
			today: today)

		let drafted = await PreparationFixture.draft(
			request, head: head, reads: intervals, today: today)

		#expect(drafted.refusal == .reviewWaiting(ReviewBase(of: head)))
	}

	@Test func aRevisionOfAnOlderBaseIsRefusedAsStale() async throws {
		let head = try ReviewStages()[.approval]
		let request = try PreparationFixture.request(
			#"{"kind":"replace","base":{"setId":"00T47DW5000000000000000100","revision":2},"changes":[\#(PreparationFixture.ride(on: "1998-09-09"))]}"#,
			today: today)

		let drafted = await PreparationFixture.draft(
			request, head: head, reads: intervals, today: today)

		#expect(drafted.refusal == .staleBase(current: ReviewBase(of: head)))
	}

	@Test func aRevisionNamingAnItemOutsideThePendingReviewIsRefused() async throws {
		let head = try ReviewStages()[.approval]
		let request = try PreparationFixture.request(
			#"{"kind":"revise","base":{"setId":"00T47DW5000000000000000100","revision":1},"replacements":[{"id":"00T47DW5000000000000000409","change":{"kind":"delete","eventId":101}}]}"#,
			today: "1998-06-13")

		let drafted = await PreparationFixture.draft(
			request, head: head, reads: intervals, today: "1998-06-13")

		#expect(drafted.refusal == .unknownItem(reviewChange(409)))
	}

	@Test func aRevisionKeepsItemIdsAndTheReplacedAddsCalendarIdentity() async throws {
		let head = try ReviewStages()[.approval]
		let request = try PreparationFixture.request(
			#"{"kind":"revise","base":{"setId":"00T47DW5000000000000000100","revision":1},"replacements":[{"id":"00T47DW5000000000000000401","change":\#(PreparationFixture.ride(on: "1998-06-16"))}]}"#,
			today: "1998-06-13")

		let drafted = await PreparationFixture.draft(
			request, head: head, reads: intervals, today: "1998-06-13")

		let remaining = try #require(drafted.remaining)
		#expect(
			remaining.map(\.reuse) == [reviewChange(401), reviewChange(402), reviewChange(403)])
		#expect(
			remaining.dropFirst().map(\.action) == head.work.remaining.dropFirst().map(\.action))
		guard case .add(let before) = head.work.remaining.first?.action,
			case .add(let after) = remaining.first?.action
		else {
			Issue.record("the revised first item is not an add")
			return
		}
		#expect(after.identity == before.identity)
		#expect(after.payload.name == "Threshold 2x2")
		#expect(try #require(drafted.draft).base == ReviewBase(of: head))
	}
}
