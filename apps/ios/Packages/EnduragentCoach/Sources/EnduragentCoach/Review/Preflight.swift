import Foundation

package enum TargetRead: Equatable, Sendable {
	case found(CalendarEvent)
	case missing
	case unreadable

	var event: CalendarEvent? {
		if case .found(let event) = self { return event }
		return nil
	}

	var date: CivilDate? {
		event.flatMap { CivilDate(rawValue: String($0.startDateLocal.prefix(10))) }
	}
}

package enum ListRead: Equatable, Sendable {
	case listed([CalendarEvent])
	case unreadable
}

package struct PreflightReads: Equatable, Sendable {
	package let account: TrainingAccount
	package let targets: [EventID: TargetRead]
	package let days: [CivilDate: ListRead]
	package let windows: [CivilDate: ListRead]

	package init(
		account: TrainingAccount, targets: [EventID: TargetRead] = [:],
		days: [CivilDate: ListRead] = [:], windows: [CivilDate: ListRead] = [:]
	) {
		self.account = account
		self.targets = targets
		self.days = days
		self.windows = windows
	}

	fileprivate func target(of change: ReviewChange) -> TargetRead? {
		change.action.target.map { targets[$0.event] ?? .unreadable }
	}
}

package enum PreflightVerdict: Equatable, Sendable {
	case clear(kept: [KeptWorkout], seen: [ChangeID: EventID])
	case changed(
		targets: [ChangeID: WorkoutSnapshot], kept: [KeptWorkout], differences: [TargetDifference])
	case blocked(ReviewBlock)
	case unchecked
}

package enum Preflight {
	package static func run(
		_ review: WorkoutReview, connection: TrainingConnection, clock: any Clock
	) async -> PreflightVerdict {
		let today = IntervalsPolicy.today(now: clock.now, timeZone: clock.timeZone)
		guard review.account.authority(under: connection.account).permitsWrites,
			case .connected(let training) = connection
		else {
			return judge(review, reads: PreflightReads(account: connection.account), today: today)
		}
		let reads = await read(
			review.work.remaining, account: training.account, from: training.client)
		return judge(review, reads: reads, today: today)
	}

	package static func judge(_ review: WorkoutReview, reads: PreflightReads, today: CivilDate)
		-> PreflightVerdict
	{
		let remaining = review.work.remaining
		guard reads.account != .unconnected else { return .blocked(.trainingNotConnected) }
		guard review.account.authority(under: reads.account).permitsWrites else {
			return .blocked(.accountChanged)
		}
		if remaining.contains(where: { reads.target(of: $0) == .missing }) {
			return .blocked(.cannotVerify)
		}
		if let refusal = remaining.lazy.compactMap({ ineligibility(of: $0, reads, today) }).first {
			return .blocked(refusal.block)
		}
		if remaining.contains(where: \.isUpgradedWithoutSnapshot) {
			return .blocked(.reviewedBeforeUpgrade)
		}
		do throws(PreflightGap) {
			let current = try currentSnapshots(of: remaining, reads)
			let kept = try keptWorkouts(
				review.work, on: affectedDates(of: remaining, reads.targets), reads.days)
			let seen = try seenAdds(remaining, reads.windows)
			let differences = namedDifferences(of: remaining, from: current)
			return differences.isEmpty
				? .clear(kept: kept, seen: seen)
				: .changed(targets: current, kept: kept, differences: differences)
		} catch {
			return .unchecked
		}
	}

	private static func read(
		_ remaining: [ReviewChange], account: TrainingAccount, from client: any CalendarReads
	) async -> PreflightReads {
		var targets: [EventID: TargetRead] = [:]
		for target in remaining.compactMap(\.action.target) {
			targets[target.event] = await read(target.event, from: client)
		}
		var days: [CivilDate: ListRead] = [:]
		for date in affectedDates(of: remaining, targets) {
			days[date] = await list(.day(date), from: client)
		}
		var windows: [CivilDate: ListRead] = [:]
		for date in remaining.compactMap(\.action.addDate) where windows[date] == nil {
			windows[date] = await list(.addWindow(around: date), from: client)
		}
		return PreflightReads(account: account, targets: targets, days: days, windows: windows)
	}

	private static func read(_ event: EventID, from client: any CalendarReads) async -> TargetRead {
		do {
			return .found(try await client.fetchEvent(id: event))
		} catch let error as IntervalsError where error.status == 404 {
			return .missing
		} catch {
			return .unreadable
		}
	}

	private static func list(_ range: ReadRange, from client: any CalendarReads) async -> ListRead {
		do {
			return .listed(try await client.listEvents(in: range))
		} catch {
			return .unreadable
		}
	}

	private static func affectedDates(
		of remaining: [ReviewChange], _ targets: [EventID: TargetRead]
	) -> [CivilDate] {
		var dates: [CivilDate] = []
		for change in remaining {
			let date: CivilDate? =
				switch change.action {
				case .add(let add): add.payload.date
				case .edit(let edit): edit.patch.date ?? targets[edit.target.event]?.date
				case .delete(let delete): targets[delete.target.event]?.date
				}
			if let date, !dates.contains(date) {
				dates.append(date)
			}
		}
		return dates
	}

	private static func ineligibility(
		of change: ReviewChange, _ reads: PreflightReads, _ today: CivilDate
	) -> Ineligibility? {
		switch change.action {
		case .add(let add):
			Eligibility.refusal(ofAddOn: add.payload.date, today: today)
		case .edit(let edit):
			reads.targets[edit.target.event]?.event.flatMap {
				Eligibility.refusal(of: $0, destination: edit.patch.date, today: today)
			}
		case .delete(let delete):
			reads.targets[delete.target.event]?.event.flatMap {
				Eligibility.refusal(of: $0, destination: nil, today: today)
			}
		}
	}

	private static func currentSnapshots(of remaining: [ReviewChange], _ reads: PreflightReads)
		throws(PreflightGap) -> [ChangeID: WorkoutSnapshot]
	{
		var current: [ChangeID: WorkoutSnapshot] = [:]
		for change in remaining where change.action.target != nil {
			guard let event = reads.target(of: change)?.event else { throw PreflightGap() }
			do {
				current[change.id] = try event.snapshot
			} catch {
				throw PreflightGap()
			}
		}
		return current
	}

	private static func keptWorkouts(
		_ work: ReviewWork, on dates: [CivilDate], _ days: [CivilDate: ListRead]
	) throws(PreflightGap) -> [KeptWorkout] {
		let own = OwnEvents(work)
		var kept: [KeptWorkout] = []
		for date in dates {
			guard case .listed(let events) = days[date] else { throw PreflightGap() }
			kept += KeptWorkout.listed(events, on: date, leaving: own.contains)
		}
		return kept
	}

	private static func seenAdds(_ remaining: [ReviewChange], _ windows: [CivilDate: ListRead])
		throws(PreflightGap) -> [ChangeID: EventID]
	{
		var seen: [ChangeID: EventID] = [:]
		for change in remaining {
			guard case .add(let add) = change.action else { continue }
			guard case .listed(let events) = windows[add.payload.date] else {
				throw PreflightGap()
			}
			switch add.onCalendar(events) {
			case .absent: continue
			case .found(let event): seen[change.id] = event
			case .ambiguous: throw PreflightGap()
			}
		}
		return seen
	}

	private static func namedDifferences(
		of remaining: [ReviewChange], from current: [ChangeID: WorkoutSnapshot]
	) -> [TargetDifference] {
		remaining.compactMap { change in
			guard case .reviewed(_, let reviewed) = change.action.target,
				let now = current[change.id]
			else { return nil }
			let difference = TargetDifference(change: change.id, before: reviewed, after: now)
			return difference.fields.isEmpty ? nil : difference
		}
	}
}

private struct PreflightGap: Error {}

private struct OwnEvents {
	let events: Set<EventID>
	let identities: Set<String>

	init(_ work: ReviewWork) {
		let changes = work.finished.map(\.change) + work.remaining
		let results: [EventID] = work.finished.compactMap {
			switch $0.result {
			case .saved(let receipt): receipt.event
			case .seenOnCalendar(let event): event
			case .noLongerOnCalendar: nil
			}
		}
		events = Set(changes.compactMap(\.action.target?.event) + results)
		identities = Set(
			changes.compactMap {
				if case .add(let add) = $0.action { add.identity.externalID } else { nil }
			})
	}

	func contains(_ event: CalendarEvent) -> Bool {
		events.contains(event.id) || event.externalId.map(identities.contains) == true
	}
}

extension ChangeAction {
	fileprivate var addDate: CivilDate? {
		if case .add(let add) = self { return add.payload.date }
		return nil
	}
}
