import Foundation

package struct ChangeID: Hashable, Sendable {
	package let ulid: ULID

	package init(ulid: ULID) {
		self.ulid = ulid
	}
}

package enum SnapshotField: String, Hashable, Sendable, CaseIterable {
	case date, name, duration, description, load, structure
}

extension WorkoutSnapshot {
	package func differences(from current: WorkoutSnapshot) -> Set<SnapshotField> {
		let reviewed = comparable
		let now = current.comparable
		let changed: [(field: SnapshotField, differs: Bool)] = [
			(.date, reviewed.date != now.date),
			(.name, reviewed.name != now.name),
			(.duration, reviewed.durationSeconds != now.durationSeconds),
			(.description, reviewed.description != now.description),
			(.load, reviewed.load != now.load),
			(.structure, reviewed.structure != now.structure),
		]
		return Set(changed.filter(\.differs).map(\.field))
	}

	private var comparable: WorkoutSnapshot {
		WorkoutSnapshot(
			date: date,
			name: name.map(Self.withoutTrailingWhitespace),
			durationSeconds: durationSeconds,
			description: description.map {
				Self.withoutTrailingWhitespace(Self.normalizedText($0))
			},
			load: load,
			structure: structure
		)
	}

	private static func withoutTrailingWhitespace(_ text: String) -> String {
		var trimmed = Substring(text)
		while trimmed.last?.isWhitespace == true {
			trimmed.removeLast()
		}
		return String(trimmed)
	}
}

extension WorkoutPatch {
	package func isApplied(on current: WorkoutSnapshot) -> Bool {
		applied(to: current).differences(from: current).isEmpty
	}
}

package enum ReviewedTarget: Hashable, Sendable {
	case reviewed(EventID, WorkoutSnapshot)
	case upgradedWithoutSnapshot(EventID, CivilDate)

	package var event: EventID {
		switch self {
		case .reviewed(let event, _), .upgradedWithoutSnapshot(let event, _): event
		}
	}
}

package struct AddedWorkout: Equatable, Sendable {
	package let payload: CalendarPayload
	package let identity: CalendarWriteID
}

package struct EditedWorkout: Equatable, Sendable {
	package let target: ReviewedTarget
	package let patch: WorkoutPatch
}

package struct DeletedWorkout: Equatable, Sendable {
	package let target: ReviewedTarget
}

package enum ChangeAction: Equatable, Sendable {
	case add(AddedWorkout)
	case edit(EditedWorkout)
	case delete(DeletedWorkout)
}

package struct ReviewChange: Equatable, Sendable {
	package let id: ChangeID
	package let position: Int
	package let action: ChangeAction
}

package enum ChangeResult: Equatable, Sendable {
	case saved(Receipt)
	case seenOnCalendar(EventID)
	case noLongerOnCalendar
}

package struct FinishedChange: Equatable, Sendable {
	package let change: ReviewChange
	package let result: ChangeResult
}

package struct ReviewWork: Equatable, Sendable {
	package let finished: [FinishedChange]
	package let remaining: [ReviewChange]
}

extension ReviewChange {
	var isUpgradedWithoutSnapshot: Bool {
		let target: ReviewedTarget? =
			switch action {
			case .add: nil
			case .edit(let edit): edit.target
			case .delete(let delete): delete.target
			}
		if case .upgradedWithoutSnapshot = target { return true }
		return false
	}

	func reviewing(_ current: WorkoutSnapshot?) -> ReviewChange {
		guard let current else { return self }
		let action: ChangeAction =
			switch self.action {
			case .add: self.action
			case .edit(let edit):
				.edit(
					EditedWorkout(target: .reviewed(edit.target.event, current), patch: edit.patch))
			case .delete(let delete):
				.delete(DeletedWorkout(target: .reviewed(delete.target.event, current)))
			}
		return ReviewChange(id: id, position: position, action: action)
	}
}
