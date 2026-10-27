import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

@Suite struct ReviewRevisionTests {
	let turns = ReviewTurns()

	@Test func revisingOneOfFourKeepsTheOtherThreeAndTheRenamedEditsContent() async throws {
		let coach = await turns.coach()
		let first = try await turns.committed(ReviewTurns.fourChanges, on: coach)
		let edit = try #require(first.work.remaining.dropFirst(2).first)

		let turn = try await turns.reply(
			after: [
				turns.prepare(
					turns.revise(
						first,
						[
							(
								edit.reference,
								#"{"kind":"edit","eventId":201,"patch":{"name":"Tempo"}}"#
							)
						]
					))
			], on: coach)

		let second = try #require(try await turns.head(of: coach).1)
		#expect(second.id == first.id)
		#expect(second.revision == ReviewRevision(rawValue: 2))
		#expect(second.origin.turn == turn)
		#expect(second.stage == .waiting(.approval(.revised)))
		let before = try stored(first)
		let after = try stored(second)
		#expect(after.count == 4)
		for index in [0, 1, 3] {
			#expect(after[index] == before[index])
		}
		let revised = try #require(second.work.remaining.dropFirst(2).first)
		#expect(revised.id == edit.id)
		#expect(revised.position == edit.position)
		guard case .edit(let earlier) = edit.action, case .edit(let renamed) = revised.action else {
			Issue.record("the revised item is not an edit")
			return
		}
		#expect(renamed.patch.name == "Tempo")
		#expect(renamed.patch.durationSeconds == 2_400)
		#expect(renamed.patch.description == earlier.patch.description)
		#expect(
			renamed.patch.authoredSteps?.json == (try JSONValue.parse(ReviewTurns.authoredSteps)))
		#expect(try WorkoutReviewPayload.decode(WorkoutReviewPayload.encode(second)) == second)
	}

	@Test func aReplacementKeepsBothFinishedChanges() async throws {
		let turns = ReviewTurns(
			clock: FixedClock(now: "1998-07-13T08:00:00+02:00", timeZone: "Europe/Amsterdam"))
		let waiting = try await turns.store("workout-review-two-finished")
		let coach = await turns.coach()

		_ = try await turns.reply(
			after: [
				turns.prepare(
					#"{"kind":"replace","base":\#(turns.base(of: waiting)),"changes":[\#(PreparationFixture.ride(on: "1998-07-20"))]}"#
				)
			], on: coach)

		let replaced = try #require(try await turns.head(of: coach).1)
		#expect(replaced.id == waiting.id)
		#expect(replaced.revision == waiting.revision.next)
		#expect(replaced.work.finished == waiting.work.finished)
		#expect(replaced.work.remaining.map(\.position) == [2])
		#expect(replaced.work.remaining.map(\.id) != waiting.work.remaining.map(\.id))
		#expect(replaced.stage == .waiting(.approval(.revised)))
	}

	@Test func aCommittedRevisionRetiresTheControlOfTheEarlierOne() async throws {
		let coach = await turns.coach()
		let first = try await turns.committed(ReviewTurns.oneRide, on: coach)
		let shown = try #require(try await coach.desk.snapshot(chat: .main))
		#expect(await coach.desk.decide(.presented(shown.ref)) == .presentationRecorded)
		guard
			case .armed(_, let token) = try #require(try await coach.desk.snapshot(chat: .main))
				.controls
		else {
			Issue.record("the first revision never armed")
			return
		}
		let ride = try #require(first.work.remaining.first)

		_ = try await turns.reply(
			after: [
				turns.prepare(
					turns.revise(
						first, [(ride.reference, PreparationFixture.ride(on: "1998-09-12"))]))
			], on: coach)

		let approval = await coach.desk.decide(.approve(token))
		let cancellation = await coach.desk.decide(.cancel(token))

		let current = try #require(try await coach.desk.snapshot(chat: .main))
		#expect(current.ref.revision == ReviewRevision(rawValue: 2))
		#expect(current.controls == .none)
		#expect(approval == .staleControl(newer: current.ref))
		#expect(cancellation == .staleControl(newer: current.ref))
	}

	@Test func anOldBaseOrACompleteSetWhileOneWaitsIsRefusedAndTheReviewStays() async throws {
		let coach = await turns.coach()
		let first = try await turns.committed(ReviewTurns.oneRide, on: coach)
		let ride = try #require(first.work.remaining.first)
		_ = try await turns.reply(
			after: [
				turns.prepare(
					turns.revise(
						first, [(ride.reference, PreparationFixture.ride(on: "1998-09-12"))]))
			], on: coach)
		let waiting = try await turns.head(of: coach)

		let turn = try await turns.reply(
			after: [
				turns.prepare(
					turns.revise(
						first, [(ride.reference, PreparationFixture.ride(on: "1998-09-13"))])),
				.finish(reason: .toolCalls),
				turns.prepare(ReviewTurns.oneRide),
			], on: coach)

		#expect(
			try turns.toolData().map { $0.objectFields["error"] } == [
				.string("stale_base"), .string("review_waiting"),
			])
		let after = try await turns.head(of: coach)
		#expect(after.0 == waiting.0)
		#expect(after.1 == waiting.1)
		#expect(try await turns.settled(turn).map(\.reviewNotPrepared) == [.refused])
		#expect(try await turns.view(of: turn, on: coach).reviewNotice == ReviewTurns.notPrepared)
	}

	@Test(arguments: [
		("workout-review-sending", "review_running"),
		("workout-review-unconfirmed", "review_unconfirmed"),
	])
	func aRunningOrUnconfirmedReviewRefusesPreparation(_ fixture: String, _ code: String)
		async throws
	{
		let busy = try await turns.store(fixture)
		let coach = await turns.coach()
		let before = try await turns.head(of: coach)

		_ = try await turns.reply(after: [turns.prepare(ReviewTurns.oneRide)], on: coach)

		#expect(try turns.toolData().first?.objectFields["error"] == .string(code))
		let after = try await turns.head(of: coach)
		#expect(after.0 == before.0)
		#expect(after.1 == busy)
	}

	@Test(arguments: [
		(
			"an event id as an item id", #"{"id":"201","change":{"kind":"delete","eventId":202}}"#,
			"unknown_item"
		),
		(
			"an item id as an event id",
			#"{"id":"ITEM","change":{"kind":"edit","eventId":"ITEM","patch":{"name":"Tempo"}}}"#,
			"invalid_event_id"
		),
		(
			"an item id of an earlier review",
			#"{"id":"00T47DW5000000000000000401","change":{"kind":"delete","eventId":202}}"#,
			"unknown_item"
		),
	])
	func aMisnamedItemDraftsNothingAndTheReviewStays(
		_ label: String, _ replacement: String, _ code: String
	) async throws {
		let coach = await turns.coach()
		let first = try await turns.committed(ReviewTurns.fourChanges, on: coach)
		let ride = try #require(first.work.remaining.first)
		let edit = try #require(first.work.remaining.dropFirst(2).first)
		let waiting = try await turns.head(of: coach)
		let valid = turns.revise(
			first, [(ride.reference, PreparationFixture.ride(on: "1998-09-12"))])
		let misnamed =
			#"{"kind":"revise","base":\#(turns.base(of: first)),"replacements":[\#(replacement.replacingOccurrences(of: "ITEM", with: edit.reference))]}"#

		let turn = try await turns.reply(
			after: [turns.prepare(valid), .finish(reason: .toolCalls), turns.prepare(misnamed)],
			on: coach)

		let data = try turns.toolData()
		#expect(data.first?.objectFields["kind"] == .string("prepared"))
		#expect(data.last?.objectFields["error"] == .string(code))
		let after = try await turns.head(of: coach)
		#expect(after.0 == waiting.0)
		#expect(after.1 == waiting.1)
		#expect(try await turns.view(of: turn, on: coach).reviewNotice == ReviewTurns.notPrepared)
	}

	@Test(arguments: [
		(
			"a delete becomes an edit", 3,
			#"{"kind":"edit","eventId":202,"patch":{"name":"Tempo"}}"#, "action_changed"
		),
		(
			"an edit moves to another workout", 2,
			#"{"kind":"edit","eventId":202,"patch":{"name":"Tempo"}}"#, "action_changed"
		),
		(
			"a ride becomes strength", 0, PreparationFixture.strength(on: "1998-09-09"),
			"action_changed"
		),
		("a delete stays a delete", 3, #"{"kind":"delete","eventId":202}"#, "unchanged_item"),
		("an add stays the same", 0, PreparationFixture.ride(on: "1998-09-09"), "unchanged_item"),
		(
			"an edit repeats its duration", 2,
			#"{"kind":"edit","eventId":201,"patch":{"durationSeconds":2400}}"#, "unchanged_item"
		),
	])
	func aRevisionMustChangeItsItemAndKeepItsActionAndWorkout(
		_ label: String, _ index: Int, _ change: String, _ code: String
	) async throws {
		let coach = await turns.coach()
		let first = try await turns.committed(ReviewTurns.fourChanges, on: coach)
		let item = first.work.remaining[index]
		let waiting = try await turns.head(of: coach)

		_ = try await turns.reply(
			after: [turns.prepare(turns.revise(first, [(item.reference, change)]))], on: coach)

		#expect(try turns.toolData().first?.objectFields["error"] == .string(code))
		#expect(try await turns.head(of: coach).0 == waiting.0)
	}

	@Test func authoredStepsAreStoredWithTheirChangesAndOldRowsHaveNone() async throws {
		let coach = await turns.coach()
		let review = try await turns.committed(ReviewTurns.fourChanges, on: coach)
		let decoded = try WorkoutReviewPayload.decode(WorkoutReviewPayload.encode(review))

		guard case .add(let ride) = decoded.work.remaining.first?.action,
			case .add(let strength) = decoded.work.remaining.dropFirst().first?.action,
			case .edit(let edit) = decoded.work.remaining.dropFirst(2).first?.action
		else {
			Issue.record("the committed changes are not add, add, edit")
			return
		}
		let workout = try JSONValue.parse(PreparationFixture.ride(on: "1998-09-09"))
			.objectFields["workout"]
		#expect(ride.payload.authoredSteps?.json == workout)
		#expect(strength.payload.authoredSteps == nil)
		#expect(edit.patch.authoredSteps?.json == (try JSONValue.parse(ReviewTurns.authoredSteps)))
		guard
			case .add(let old) = try reviewFixture("workout-review-approval").work.remaining.first?
				.action
		else {
			Issue.record("the stored fixture does not start with an add")
			return
		}
		#expect(old.payload.authoredSteps == nil)
	}

	private func stored(_ review: WorkoutReview) throws -> [JSONValue] {
		let encoded = String(decoding: try WorkoutReviewPayload.encode(review), as: UTF8.self)
		return try #require(try JSONValue.parse(encoded).objectFields["remaining"]?.arrayValue)
	}
}
