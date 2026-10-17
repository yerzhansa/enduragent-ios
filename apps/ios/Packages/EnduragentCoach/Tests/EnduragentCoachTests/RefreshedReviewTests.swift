import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

@Suite struct RefreshedReviewTests {
	typealias Fixture = PreflightFixture

	let intervals = FakeIntervalsClient(athleteName: "Ada", ftp: 250)
	let approved = FixedClock(now: "1998-09-08T00:30:00+12:00", timeZone: "Pacific/Auckland")
	let english = displayLocale()

	static let edited = Fixture.workout(201, on: "1998-09-10")
	static let deleted = Fixture.workout(
		202, on: "1998-09-11", name: "Recovery spin", minutes: 30, load: 20)
	static let kept = Fixture.workout(203, on: "1998-09-10", name: "Group ride", minutes: 120)
	static let headline =
		"Workouts in this review changed in intervals.icu after you reviewed them, so nothing was changed. Check them again before you approve."

	static func mixedSet(finished: [FinishedChange] = []) throws -> WorkoutReview {
		try Fixture.review(
			[
				Fixture.ride(on: "1998-09-10"),
				try Fixture.edit(edited, Fixture.patch(minutes: 75)), try Fixture.delete(deleted),
			], finished: finished)
	}

	static var longer: CalendarEvent {
		var longer = edited
		longer.movingTime = 5400
		return longer
	}

	@Test func aWorkoutChangedFrom60To90IsReviewedAt90AndStillAsksFor75() async throws {
		let review = try Self.mixedSet()
		intervals.events = [Self.longer, Self.deleted, Self.kept]

		let refreshed = try await savedRefresh(of: review)

		#expect(refreshed.revision == review.revision.next)
		let change = try #require(refreshed.work.remaining.first { $0.id == Fixture.change(1) })
		guard case .edit(let edit) = change.action, case .reviewed(_, let reviewed) = edit.target
		else {
			throw UnexpectedReview(detail: "the refreshed change is not a reviewed edit")
		}
		#expect(reviewed.durationSeconds == 5400)
		#expect(edit.patch.applied(to: reviewed).durationSeconds == 4500)
		let card = try #require(snapshot(of: refreshed).cards.first { $0.index == 1 })
		#expect(card.durationMinutes == 75)
		#expect(refreshed.allowedControls == .approveOrCancel)
	}

	@Test func theNoticeNamesTheWorkoutItsDurationAndThatNothingWasChanged() async throws {
		intervals.events = [Self.longer, Self.deleted, Self.kept]

		let refreshed = try await savedRefresh(of: try Self.mixedSet())

		#expect(
			try sentences(of: refreshed) == [
				Self.headline, "Endurance: duration changed from 60 to 90 minutes.",
			])
	}

	@Test func theRefreshedOutcomeNoticeReadsEveryChangedFieldAfterApproval() async throws {
		let rig = DeskRig()
		try await rig.save(try rig.mixed())
		rig.base.events[0].movingTime = 90 * 60
		let desk = try rig.desk()

		let outcome = await desk.decide(.approve(try await rig.token(on: desk)))

		guard case .refreshed = outcome else {
			Issue.record("the changed workout gave \(outcome)")
			return
		}
		#expect(
			outcome.notice?.sentence(in: english)
				== Self.headline + " Endurance: duration changed from 60 to 90 minutes.")
		#expect(rig.calendar.writes.isEmpty)
	}

	@Test func aRefreshAfterFinishedWorkSaysNothingElseWasChanged() async throws {
		let finished = FinishedChange(
			change: ReviewChange(
				id: reviewChange(590), position: 0,
				action: Fixture.ride(on: "1998-09-09", identity: CalendarWriteID())),
			result: .seenOnCalendar(EventID(rawValue: 300)))
		intervals.events = [Self.longer, Self.deleted, Self.kept]

		let refreshed = try await savedRefresh(of: try Self.mixedSet(finished: [finished]))

		#expect(
			try sentences(of: refreshed) == [
				"Workouts in this review changed in intervals.icu after you reviewed them, so nothing else was changed. Check them again before you approve.",
				"Endurance: duration changed from 60 to 90 minutes.",
			])
	}

	@Test(arguments: SnapshotField.allCases)
	func eachFieldChangedAloneGivesItsOwnSentence(_ field: SnapshotField) async throws {
		let target = Fixture.stepped(201, on: "1998-09-10")
		var current = target
		let sentence: String
		switch field {
		case .date:
			current.startDateLocal = "1998-09-12T00:00:00"
			sentence =
				"Sweet spot: date changed from \(english.date("1998-09-10", style: .numeric)) to \(english.date("1998-09-12", style: .numeric))."
		case .name:
			current.name = "Sweet spot plus"
			sentence = "Sweet spot: name changed to Sweet spot plus."
		case .duration:
			current.movingTime = 3600
			sentence = "Sweet spot: duration changed from 55 to 60 minutes."
		case .description:
			current.description = "Ride by feel"
			sentence = "Sweet spot: description changed."
		case .load:
			current.trainingLoad = 70
			sentence = "Sweet spot: training load changed from 61 to 70."
		case .structure:
			current.workoutDocument = Fixture.derivedDocument(
				steps: .array([.object(["duration": .number(3300)])]), averageWatts: 180)
			sentence = "Sweet spot: workout steps changed."
		}
		let review = try Fixture.review([try Fixture.edit(target, Fixture.patch(minutes: 75))])
		intervals.events = [current]

		let refreshed = try await savedRefresh(of: review)

		#expect(try sentences(of: refreshed) == [Self.headline, sentence])
	}

	@Test func twoChangedWorkoutsGiveTwoSentences() async throws {
		var lighter = Self.deleted
		lighter.trainingLoad = 25
		intervals.events = [Self.longer, lighter, Self.kept]

		let refreshed = try await savedRefresh(of: try Self.mixedSet())

		#expect(
			try sentences(of: refreshed) == [
				Self.headline, "Endurance: duration changed from 60 to 90 minutes.",
				"Recovery spin: training load changed from 20 to 25.",
			])
	}

	@Test func theKeptWorkoutsAreTheOnesReadAtPreflight() async throws {
		let review = try Self.mixedSet()
		let club = Fixture.workout(204, on: "1998-09-11", name: "Club ride", minutes: 90)
		intervals.events = [Self.longer, Self.deleted, club]

		let refreshed = try await savedRefresh(of: review)

		let read = [KeptWorkout(name: "Club ride", date: "1998-09-11", durationMinutes: 90)]
		#expect(review.kept.isEmpty)
		#expect(refreshed.kept == read)
		#expect(snapshot(of: refreshed).kept == read)
	}

	private func savedRefresh(of review: WorkoutReview) async throws -> WorkoutReview {
		let claimed = try review.claimed(Claim(id: claimID(1), action: .approve))
		guard
			case .changed(let targets, let kept, let differences) = await Preflight.run(
				claimed, connection: connection, clock: approved)
		else {
			throw UnexpectedReview(detail: "preflight named no changed workout")
		}
		let refreshed = try claimed.refreshed(targets, kept: kept, differences: differences)
		let ledger = Ledger(
			log: InMemoryRecordLog(deviceId: DeviceID(rawValue: "refreshed-phone")),
			clock: approved, diagnostics: DiagnosticsLog(clock: approved))
		var head = RecordHead.empty
		for value in [review, claimed, refreshed] {
			let record = try await ledger.commit(
				review: value,
				stamp: testStamp(operation: .workoutReview(value.id, value.revision)), after: head)
			head = .record(record.ulid)
		}
		let (saved, stored) = try await ledger.reviewHead(chat: review.chat)
		#expect(saved == head)
		return try #require(stored)
	}

	private var connection: TrainingConnection {
		guard case .intervals(let connection, let athlete?) = Fixture.account else {
			return .unconnected
		}
		return .connected(
			ConnectedTraining(connection: connection, athlete: athlete, client: intervals))
	}

	private func snapshot(of review: WorkoutReview) -> ReviewSnapshot {
		ReviewProjection.snapshot(
			of: review, delivery: Delivery.fresh(for: review, at: reviewULID(601)),
			placement: .afterTurn(review.origin.turn),
			attribution: AthleteAttribution(
				accounts: [review.account], using: InformationOwnership(records: []),
				device: DeviceID(rawValue: "refreshed-phone")))
	}

	private func sentences(of review: WorkoutReview) throws -> [String] {
		try #require(snapshot(of: review).notice).sentences(in: english)
	}
}
