import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

@Suite struct PreflightRunTests {
	typealias Fixture = PreflightFixture

	let intervals = FakeIntervalsClient(athleteName: "Ada", ftp: 250)
	let prepared = FixedClock(now: "1998-09-07T23:30:00+12:00", timeZone: "Pacific/Auckland")
	let approved = FixedClock(now: "1998-09-08T00:30:00+12:00", timeZone: "Pacific/Auckland")

	static let edited = Fixture.workout(201, on: "1998-09-10")
	static let deleted = Fixture.workout(
		202, on: "1998-09-11", name: "Recovery spin", minutes: 30, load: 20)
	static let kept = Fixture.workout(203, on: "1998-09-10", name: "Group ride", minutes: 120)
	static let addDate: CivilDate = "1998-09-10"
	static let keptWorkout = KeptWorkout(
		name: "Group ride", date: "1998-09-10", durationMinutes: 120)

	static func mixedSet() throws -> WorkoutReview {
		try Fixture.review([
			Fixture.ride(on: "1998-09-10"), try Fixture.edit(edited, Fixture.patch(minutes: 75)),
			try Fixture.delete(deleted),
		])
	}

	var connection: TrainingConnection {
		connected(as: Fixture.account)
	}

	func connected(as account: TrainingAccount) -> TrainingConnection {
		guard case .intervals(let connection, let athlete?) = account else { return .unconnected }
		return .connected(
			ConnectedTraining(connection: connection, athlete: athlete, client: intervals))
	}

	func preflight(_ review: WorkoutReview, at clock: FixedClock? = nil) async -> PreflightVerdict {
		await Preflight.run(review, connection: connection, clock: clock ?? approved)
	}

	var writes: [FakeIntervalsCall] {
		intervals.calls.filter {
			switch $0 {
			case .createEvent, .updateEvent, .deleteEvent: true
			default: false
			}
		}
	}

	@Test func readsEachAffectedDayAndEachAddWindowOnceAndWritesNothing() async throws {
		intervals.events = [Self.edited, Self.deleted, Self.kept]

		let verdict = await preflight(try Self.mixedSet())

		#expect(verdict == .clear(kept: [Self.keptWorkout], seen: [:]))
		let window = ReadRange.addWindow(around: "1998-09-10")
		#expect(
			intervals.calls == [
				.events(oldest: "1998-09-10", newest: "1998-09-10"),
				.events(oldest: "1998-09-11", newest: "1998-09-11"),
				.events(oldest: window.oldest, newest: window.newest),
			])
		#expect(window.oldest == "1998-03-11")
		#expect(window.newest == CivilDate("1998-03-11").adding(days: 365))
	}

	enum Target: String, CaseIterable, Sendable {
		case edit, delete

		var proposed: ProposedChange {
			switch self {
			case .edit: .edit(EventID(rawValue: 201), Fixture.patch(minutes: 75))
			case .delete: .delete(EventID(rawValue: 201))
			}
		}
	}

	@Test(arguments: Target.allCases)
	func aTargetOfTheEveningBeforeIsPastWhenApprovedAfterMidnightInAuckland(_ target: Target)
		async throws
	{
		intervals.events = [Fixture.workout(201, on: "1998-09-07")]
		let review = try await reviewPrepared(.complete([target.proposed]))

		#expect(await preflight(review) == .blocked(.pastProtected))
		#expect(writes.isEmpty)
	}

	@Test func anAddOfTheEveningBeforeIsPastWhenApprovedAfterMidnightInAuckland() async throws {
		guard case .add(let ride) = Fixture.ride(on: "1998-09-07") else {
			throw UnexpectedReview(detail: "the fixture ride is not an add")
		}
		let review = try await reviewPrepared(.complete([.add(ride.payload)]))

		#expect(await preflight(review) == .blocked(.pastProtected))
		#expect(writes.isEmpty)
	}

	@Test func aDeleteTargetGoneFromIntervalsCannotBeVerified() async throws {
		intervals.events = [Self.edited, Self.kept]

		#expect(await preflight(try Self.mixedSet()) == .blocked(.cannotVerify))
		#expect(writes.isEmpty)
	}

	@Test func anotherAthletesKeyAfterReviewBlocksBeforeAnyRead() async throws {
		intervals.events = [Self.edited, Self.deleted, Self.kept]

		let verdict = await Preflight.run(
			try Self.mixedSet(), connection: connected(as: Fixture.otherAthlete), clock: approved)

		#expect(verdict == .blocked(.accountChanged))
		#expect(intervals.calls.isEmpty)
	}

	enum Unreadable: String, CaseIterable, Sendable {
		case target, keptDay, addWindow
	}

	@Test(arguments: Unreadable.allCases)
	func oneUnreadableReadLeavesTheWholeVerdictUnchecked(_ unreadable: Unreadable) async throws {
		intervals.events = [Self.edited, Self.deleted, Self.kept]
		switch unreadable {
		case .target: intervals.unreadableEvents = [Self.deleted.id]
		case .keptDay: intervals.unreadableLists = [.day("1998-09-11")]
		case .addWindow: intervals.unreadableLists = [.addWindow(around: "1998-09-10")]
		}

		#expect(await preflight(try Self.mixedSet()) == .unchecked)
		#expect(writes.isEmpty)
	}

	@Test(arguments: [0, 30, -30])
	func anAddAlreadyInItsWindowIsSeenAndNotKept(movedDays: Int) async throws {
		let saved = Fixture.carrying(
			Fixture.rideIdentity, 301, on: Self.addDate.adding(days: movedDays))
		intervals.events = [Self.edited, Self.deleted, Self.kept, saved]

		let verdict = await preflight(try Self.mixedSet())

		#expect(
			verdict
				== .clear(
					kept: [Self.keptWorkout], seen: [Fixture.change(0): EventID(rawValue: 301)]))
	}

	@Test func anAddIsSeenOnlyByItsOwnExternalIDWithinItsWindow() async throws {
		var uidOnly = Fixture.carrying(CalendarWriteID(), 301, on: "1998-09-10")
		uidOnly.uid = Fixture.rideIdentity.uid
		let outside = Fixture.carrying(
			Fixture.rideIdentity, 302, on: Self.addDate.adding(days: 183))
		intervals.events = [Self.edited, Self.deleted, Self.kept, uidOnly, outside]

		let verdict = await preflight(try Self.mixedSet())

		#expect(
			verdict
				== .clear(
					kept: [
						Self.keptWorkout,
						KeptWorkout(name: "Tempo ride", date: "1998-09-10", durationMinutes: 50),
					],
					seen: [:]))
	}

	@Test func twoEventsCarryingAnAddsExternalIDLeaveTheVerdictUnchecked() async throws {
		intervals.events = [
			Self.edited, Self.deleted, Self.kept,
			Fixture.carrying(Fixture.rideIdentity, 301, on: "1998-09-10"),
			Fixture.carrying(Fixture.rideIdentity, 302, on: "1998-09-24"),
		]

		#expect(await preflight(try Self.mixedSet()) == .unchecked)
	}

	@Test func aChangeMadeOnIntervalsAfterPreflightAndBeforeTheWriteIsNotDetected() async throws {
		intervals.events = [Self.edited]
		let review = try Fixture.review([try Fixture.edit(Self.edited, Fixture.patch(minutes: 75))])

		let verdict = await preflight(review)
		var athleteEdit = Self.edited
		athleteEdit.movingTime = 5400
		intervals.events = [athleteEdit]
		let sending = try review.claimed(Claim(id: claimID(1), action: .approve))
			.sending(at: reviewClock, seen: try #require(verdict.seen))
		guard case .running(let run) = sending.stage, let attempt = run.sending else {
			throw UnexpectedReview(detail: "the cleared review started no send attempt")
		}
		let answer = await CalendarWriter.send(attempt, on: intervals, now: reviewClock)

		#expect(verdict == .clear(kept: [], seen: [:]))
		guard case .saved(let receipt) = answer else {
			Issue.record("the edit answered \(answer)")
			return
		}
		#expect(receipt.event == Self.edited.id)
		#expect(
			intervals.calls == [
				.events(oldest: "1998-09-10", newest: "1998-09-10"), .updateEvent(Self.edited.id),
			])
	}

	private func reviewPrepared(_ request: PreparationRequest) async throws -> WorkoutReview {
		let today = IntervalsPolicy.today(now: prepared.now, timeZone: prepared.timeZone)
		let remaining = try #require(
			await PreparationFixture.draft(request, reads: intervals, today: today).remaining)
		return try Fixture.review(remaining.map(\.action))
	}
}
