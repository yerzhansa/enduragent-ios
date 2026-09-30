import Foundation

package enum StepType: String, Sendable {
	case warmup
	case cooldown
	case set
	case ramp
	case freeride
	case rest
	case interval
	case steady
	case recovery
}

package enum PowerKind: String, Sendable {
	case watts
	case percentFtp = "percent_ftp"
	case zone
}

package struct DurationInput: Sendable, Equatable {
	package var value: Double
	package var unit: Unit

	package enum Unit: String, Sendable {
		case seconds
		case minutes
	}
}

package struct PowerTarget: Sendable, Equatable {
	package var kind: PowerKind
	package var value: Double?
	package var low: Double?
	package var high: Double?
}

package struct CadenceTarget: Sendable, Equatable {
	package var value: Int?
	package var low: Int?
	package var high: Int?
}

package struct SimpleStep: Sendable, Equatable {
	package var type: StepType
	package var duration: DurationInput
	package var power: PowerTarget?
	package var cadence: CadenceTarget?
	package var label: String?
}

package struct SetStep: Sendable, Equatable {
	package var repeatCount: Int
	package var interval: SimpleStep
	package var recovery: SimpleStep
}

package enum WorkoutStep: Sendable, Equatable {
	case simple(SimpleStep)
	case set(SetStep)
}

package struct IntervalsWorkoutInput: Sendable, Equatable {
	package var name: String
	package var steps: [WorkoutStep]
}

package struct SerializedWorkout: Sendable, Equatable {
	package var description: String
	package var movingTime: Int
}

package struct InvalidWorkout: Error, Sendable, Equatable {
	package var message: String
}
