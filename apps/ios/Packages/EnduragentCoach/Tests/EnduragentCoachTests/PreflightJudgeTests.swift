import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

@Suite struct PreflightJudgeTests {
	typealias Fixture = PreflightFixture

	struct Calendar {
		var account = Fixture.account
		var events: [CalendarEvent]
		var targets: [EventID: TargetRead] = [:]

		init(_ events: [CalendarEvent]) {
			self.events = events
		}

		var reads: PreflightReads {
			let days = (1...30).compactMap {
				CivilDate(rawValue: String(format: "1998-09-%02d", $0))
			}
			let found = Dictionary(
				uniqueKeysWithValues: events.map { ($0.id, TargetRead.found($0)) })
			return PreflightReads(
				account: account, targets: found.merging(targets) { _, override in override },
				days: Dictionary(
					uniqueKeysWithValues: days.map { day in
						(
							day,
							ListRead.listed(
								events.filter { $0.startDateLocal.hasPrefix(day.rawValue) })
						)
					}),
				windows: Dictionary(
					uniqueKeysWithValues: days.map { ($0, ListRead.listed(events)) }))
		}

		mutating func replace(_ event: CalendarEvent) {
			targets[event.id] = .found(event)
		}
	}

	static let edited = Fixture.workout(201, on: "1998-09-10")
	static let deleted = Fixture.workout(
		202, on: "1998-09-11", name: "Recovery spin", minutes: 30, load: 20)
	static let kept = Fixture.workout(203, on: "1998-09-10", name: "Group ride", minutes: 120)

	static func mixedSet() throws -> WorkoutReview {
		try Fixture.review([
			Fixture.ride(on: "1998-09-10"), try Fixture.edit(edited, Fixture.patch(minutes: 75)),
			try Fixture.delete(deleted),
		])
	}

	static func judged(_ review: WorkoutReview, _ calendar: Calendar) -> PreflightVerdict {
		Preflight.judge(review, reads: calendar.reads, today: Fixture.today)
	}

	enum Fault: Int, CaseIterable, Comparable, Sendable, CustomTestStringConvertible {
		case account, missing, ineligible, upgraded, unreadable, changed

		static func < (left: Fault, right: Fault) -> Bool { left.rawValue < right.rawValue }

		var testDescription: String { "\(self)" }

		var verdict: PreflightVerdict.Kind {
			switch self {
			case .account: .accountChanged
			case .missing: .cannotVerify
			case .ineligible: .workoutOnly
			case .upgraded: .reviewedBeforeUpgrade
			case .unreadable: .unchecked
			case .changed: .changed
			}
		}

		func apply(on target: CalendarEvent, _ calendar: inout Calendar) {
			var current = target
			switch self {
			case .account: calendar.account = Fixture.otherAthlete
			case .missing: calendar.targets[target.id] = .missing
			case .unreadable: calendar.targets[target.id] = .unreadable
			case .upgraded: break
			case .ineligible:
				current.category = "RACE_A"
				calendar.replace(current)
			case .changed:
				current.movingTime = 5400
				calendar.replace(current)
			}
		}

		func target(_ event: CalendarEvent, patch: WorkoutPatch) throws -> ChangeAction {
			guard self == .upgraded else { return try Fixture.edit(event, patch) }
			return .edit(
				EditedWorkout(
					target: .upgradedWithoutSnapshot(event.id, try event.snapshot.date),
					patch: patch))
		}
	}

	struct OrderPair: Sendable, CustomTestStringConvertible {
		let first: Fault
		let second: Fault
		let firstOnLastChange: Bool

		var testDescription: String {
			firstOnLastChange
				? "\(second) on the first target, \(first) on the last"
				: "\(first) on the first target, \(second) on the last"
		}
	}

	static let orderPairs: [OrderPair] = Fault.allCases.flatMap { first in
		Fault.allCases.filter { first < $0 }.flatMap { second in
			[false, true].map { OrderPair(first: first, second: second, firstOnLastChange: $0) }
		}
	}

	@Test(arguments: orderPairs)
	func anEarlierCheckDecidesTheVerdictWhenTwoTargetsFailDifferentChecks(_ pair: OrderPair)
		throws
	{
		let firstTarget = Fixture.workout(201, on: "1998-09-10")
		let lastTarget = Fixture.workout(204, on: "1998-09-12", name: "Tempo")
		let (onFirst, onLast) =
			pair.firstOnLastChange ? (pair.second, pair.first) : (pair.first, pair.second)
		var calendar = Calendar([firstTarget, lastTarget, Self.kept])
		onFirst.apply(on: firstTarget, &calendar)
		onLast.apply(on: lastTarget, &calendar)
		let review = try Fixture.review([
			Fixture.ride(on: "1998-09-10"),
			try onFirst.target(firstTarget, patch: Fixture.patch(minutes: 75)),
			try onLast.target(lastTarget, patch: Fixture.patch(minutes: 45)),
		])

		#expect(Self.judged(review, calendar).kind == pair.first.verdict)
	}

	enum Turn: String, CaseIterable, Sendable {
		case lostCoachProvenance, becameARace, datedYesterday, movedIntoYesterday

		var block: ReviewBlock {
			switch self {
			case .lostCoachProvenance: .coachOnly
			case .becameARace: .workoutOnly
			case .datedYesterday, .movedIntoYesterday: .pastProtected
			}
		}
	}

	@Test(arguments: Turn.allCases)
	func aLastChangeWhoseTargetTurnedIneligibleBlocksTheWholeSet(_ turn: Turn) throws {
		var target = Fixture.workout(
			204, on: turn == .datedYesterday ? "1998-09-07" : "1998-09-12", name: "Tempo")
		let patch = Fixture.patch(date: turn == .movedIntoYesterday ? "1998-09-07" : nil)
		let review = try Fixture.review([
			Fixture.ride(on: "1998-09-10"),
			try Fixture.edit(Self.edited, Fixture.patch(minutes: 75)),
			try Fixture.edit(target, patch),
		])
		switch turn {
		case .lostCoachProvenance: target.tags = []
		case .becameARace: target.category = "RACE_A"
		case .datedYesterday, .movedIntoYesterday: break
		}
		var calendar = Calendar([Self.edited, target, Self.kept])
		calendar.replace(target)

		#expect(Self.judged(review, calendar) == .blocked(turn.block))
	}

	@Test func aDeletedTargetCannotBeVerifiedAndNoTargetIsRefreshed() throws {
		var longer = Self.edited
		longer.movingTime = 5400
		var calendar = Calendar([longer, Self.kept])
		calendar.targets[Self.deleted.id] = .missing

		#expect(Self.judged(try Self.mixedSet(), calendar) == .blocked(.cannotVerify))
	}

	@Test func aWorkoutThatWentFrom60To90MinutesIsNamedWithItsDuration() throws {
		var longer = Self.edited
		longer.movingTime = 5400

		let verdict = Self.judged(
			try Self.mixedSet(), Calendar([longer, Self.deleted, Self.kept]))

		#expect(
			verdict
				== .changed(
					targets: [
						Fixture.change(1): try longer.snapshot,
						Fixture.change(2): try Self.deleted.snapshot,
					],
					kept: [
						KeptWorkout(name: "Group ride", date: "1998-09-10", durationMinutes: 120)
					],
					differences: [
						TargetDifference(
							change: Fixture.change(1), before: try Self.edited.snapshot,
							after: try longer.snapshot)
					])
		)
	}

	@Test(arguments: SnapshotField.allCases)
	func eachReviewedFieldChangedAloneIsNamedAlone(_ field: SnapshotField) throws {
		let target = Fixture.stepped(201, on: "1998-09-10")
		var current = target
		switch field {
		case .date: current.startDateLocal = "1998-09-12T00:00:00"
		case .name: current.name = "Sweet spot plus"
		case .duration: current.movingTime = 3600
		case .description: current.description = "Ride by feel"
		case .load: current.trainingLoad = 70
		case .structure:
			current.workoutDocument = Fixture.derivedDocument(
				steps: .array([.object(["duration": .number(3300)])]), averageWatts: 180)
		}
		let review = try Fixture.review([try Fixture.edit(target, Fixture.patch(minutes: 75))])

		let verdict = Self.judged(review, Calendar([current]))

		#expect(verdict.namedFields == [Fixture.change(0): [field]])
	}

	@Test func aLoadTheAthleteTypedIsNamedWhenTheEditSendsTheSameSteps() throws {
		let reviewed = Fixture.stepped(201, on: "1998-09-10", load: 61)
		var typed = reviewed
		typed.trainingLoad = 90
		let patch = Fixture.patch(date: "1998-09-12", description: Fixture.stepsDescription)
		let review = try Fixture.review([try Fixture.edit(reviewed, patch)])

		let verdict = Self.judged(review, Calendar([typed]))

		#expect(
			verdict
				== .changed(
					targets: [Fixture.change(0): try typed.snapshot], kept: [],
					differences: [
						TargetDifference(
							change: Fixture.change(0), before: try reviewed.snapshot,
							after: try typed.snapshot)
					]))
	}

	@Test func eligibilityIsJudgedBeforeADifferenceOnTheSameTarget() throws {
		var race = Self.edited
		race.movingTime = 5400
		race.category = "RACE_A"

		let verdict = Self.judged(try Self.mixedSet(), Calendar([race, Self.deleted, Self.kept]))

		#expect(verdict == .blocked(.workoutOnly))
	}

	@Test func aChangeOnlyInServerMetadataNeedsNoNewApproval() throws {
		var current = Self.edited
		current.startDateLocal = "1998-09-10T06:30:00"
		current.type = "VirtualRide"
		current.uid = "server-owned"
		current.tags = [IntervalsPolicy.coachTag, "imported"]
		current.movingTime = 3600

		let verdict = Self.judged(
			try Self.mixedSet(), Calendar([current, Self.deleted, Self.kept]))

		#expect(
			verdict
				== .clear(
					kept: [
						KeptWorkout(name: "Group ride", date: "1998-09-10", durationMinutes: 120)
					],
					seen: [:]))
	}
}
