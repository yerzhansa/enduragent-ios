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
		let changed: [(field: SnapshotField, differs: Bool)] = [
			(.date, date != current.date),
			(
				.name,
				name.map(Self.withoutTrailingWhitespace)
					!= current.name.map(Self.withoutTrailingWhitespace)
			),
			(.duration, durationSeconds != current.durationSeconds),
			(.description, !Self.sameDescription(description, current.description)),
			(.load, load != current.load),
			(.structure, structure != current.structure),
		]
		return Set(changed.filter(\.differs).map(\.field))
	}

	static func sameDescription(_ left: String?, _ right: String?) -> Bool {
		left.map(comparableDescription) == right.map(comparableDescription)
	}

	private static func comparableDescription(_ text: String) -> String {
		withoutTrailingWhitespace(normalizedText(text))
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
		unrewritten(applied(to: current).differences(from: current), on: current).isEmpty
	}

	func unrewritten(_ fields: Set<SnapshotField>, on current: WorkoutSnapshot)
		-> Set<SnapshotField>
	{
		guard description != nil, applied(to: current).hasParsedSteps else { return fields }
		return fields.subtracting([.load])
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

extension ChangeAction {
	var target: ReviewedTarget? {
		switch self {
		case .add: nil
		case .edit(let edit): edit.target
		case .delete(let delete): delete.target
		}
	}
}

extension ReviewChange {
	var isUpgradedWithoutSnapshot: Bool {
		if case .upgradedWithoutSnapshot = action.target { return true }
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
