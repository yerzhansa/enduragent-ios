import Foundation

package struct ChatMessage: Sendable, Equatable {
	package let author: Author
	package let text: String

	package init(author: Author, text: String) {
		self.author = author
		self.text = text
	}

	package enum Author: Sendable, Equatable {
		case athlete(sent: Date, timeZone: IANATimeZone)
		case coach
	}
}

public enum ToolName: String, Sendable, CaseIterable {
	case calculateZones = "calculate_zones"
	case intervalsFetchAthlete = "intervals_fetch_athlete"
	case intervalsFetchWellness = "intervals_fetch_wellness"
	case intervalsFetchActivity = "intervals_fetch_activity"
	case intervalsFetchStreams = "intervals_fetch_streams"
	case intervalsFetchActivities = "intervals_fetch_activities"
	case intervalsListEvents = "intervals_list_events"
	case intervalsCreateWorkout = "intervals_create_workout"
	case intervalsCreateStrengthWorkout = "intervals_create_strength_workout"
	case intervalsDeleteWorkout = "intervals_delete_workout"
	case intervalsUpdateWorkout = "intervals_update_workout"
	case getPendingWorkoutChanges = "get_pending_workout_changes"
	case prepareWorkoutChanges = "prepare_workout_changes"
	case memoryRead = "memory_read"
	case memoryQuery = "memory_query"
	case memoryWrite = "memory_write"
	case ledgerAppend = "ledger_append"
	case planSave = "plan_save"
}

package enum GatedToolName: String, Sendable {
	case intervalsCreateWorkout = "intervals_create_workout"
	case intervalsCreateStrengthWorkout = "intervals_create_strength_workout"
	case intervalsDeleteWorkout = "intervals_delete_workout"
	case intervalsUpdateWorkout = "intervals_update_workout"
	case planSave = "plan_save"

	package var toolName: ToolName {
		switch self {
		case .intervalsCreateWorkout: .intervalsCreateWorkout
		case .intervalsCreateStrengthWorkout: .intervalsCreateStrengthWorkout
		case .intervalsDeleteWorkout: .intervalsDeleteWorkout
		case .intervalsUpdateWorkout: .intervalsUpdateWorkout
		case .planSave: .planSave
		}
	}

	package static let all: Set<GatedToolName> = [
		.intervalsCreateWorkout,
		.intervalsCreateStrengthWorkout,
		.intervalsDeleteWorkout,
		.intervalsUpdateWorkout,
		.planSave,
	]
}

package enum ReplayUnsafeToolName: String, Sendable {
	case intervalsCreateWorkout = "intervals_create_workout"
	case intervalsCreateStrengthWorkout = "intervals_create_strength_workout"
	case intervalsDeleteWorkout = "intervals_delete_workout"
	case intervalsUpdateWorkout = "intervals_update_workout"
	case memoryWrite = "memory_write"
	case ledgerAppend = "ledger_append"
	case planSave = "plan_save"

	var toolName: ToolName {
		switch self {
		case .intervalsCreateWorkout: .intervalsCreateWorkout
		case .intervalsCreateStrengthWorkout: .intervalsCreateStrengthWorkout
		case .intervalsDeleteWorkout: .intervalsDeleteWorkout
		case .intervalsUpdateWorkout: .intervalsUpdateWorkout
		case .memoryWrite: .memoryWrite
		case .ledgerAppend: .ledgerAppend
		case .planSave: .planSave
		}
	}
}

enum ReadToolName: Sendable {
	case calculateZones
	case intervalsFetchAthlete
	case intervalsFetchWellness
	case intervalsFetchActivity
	case intervalsFetchStreams
	case intervalsFetchActivities
	case intervalsListEvents

	var toolName: ToolName {
		switch self {
		case .calculateZones: .calculateZones
		case .intervalsFetchAthlete: .intervalsFetchAthlete
		case .intervalsFetchWellness: .intervalsFetchWellness
		case .intervalsFetchActivity: .intervalsFetchActivity
		case .intervalsFetchStreams: .intervalsFetchStreams
		case .intervalsFetchActivities: .intervalsFetchActivities
		case .intervalsListEvents: .intervalsListEvents
		}
	}
}

enum PreparationToolName: Sendable {
	case getPendingWorkoutChanges
	case prepareWorkoutChanges

	var toolName: ToolName {
		switch self {
		case .getPendingWorkoutChanges: .getPendingWorkoutChanges
		case .prepareWorkoutChanges: .prepareWorkoutChanges
		}
	}
}

enum MemoryReadToolName: Sendable {
	case memoryRead
	case memoryQuery

	var toolName: ToolName {
		switch self {
		case .memoryRead: .memoryRead
		case .memoryQuery: .memoryQuery
		}
	}
}
