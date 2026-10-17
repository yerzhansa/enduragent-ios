import Foundation

extension WorkoutChartModel {
	init?(_ workout: IntervalsWorkoutInput) {
		let steps = workout.steps.flatMap(\.expanded)
		let kinds = Set(steps.compactMap(\.power?.kind))
		guard let unit = Unit(drawing: kinds) else { return nil }
		let segments = steps.map { $0.segment(in: unit) }
		self.init(
			unit: unit, durationSeconds: segments.map(\.durationSeconds).reduce(0, +),
			segments: segments)
	}

	public var ceiling: Double {
		if unit == .zone { return 7 }
		let highest = segments.flatMap(\.values).max() ?? 0
		let target = Swift.max(highest, unit == .percentOfFTP ? 100 : 1)
		let magnitude = pow(10, (log10(target)).rounded(.down))
		let normalized = target / magnitude
		let step: Double =
			normalized <= 1 ? 1 : normalized <= 2 ? 2 : normalized <= 5 ? 5 : 10
		return step * magnitude
	}

	public var ticks: [Double] {
		if unit == .zone { return [6, 3] }
		return [ceiling * 0.75, ceiling * 0.5]
	}
}

extension WorkoutChartModel.Segment {
	public var durationSeconds: Int {
		switch self {
		case .steady(let seconds, _), .range(let seconds, _, _), .ramp(let seconds, _, _),
			.open(let seconds):
			seconds
		}
	}

	var values: [Double] {
		switch self {
		case .steady(_, let target): [target]
		case .range(_, let low, let high): [low, high]
		case .ramp(_, let start, let end): [start, end]
		case .open: []
		}
	}
}

extension WorkoutChartModel.Unit {
	fileprivate init?(drawing kinds: Set<PowerKind>) {
		switch kinds {
		case [.watts]: self = .watts
		case [.zone]: self = .zone
		case [.percentFtp], [.percentFtp, .zone]: self = .percentOfFTP
		default: return nil
		}
	}
}

extension WorkoutStep {
	fileprivate var expanded: [SimpleStep] {
		switch self {
		case .simple(let step): [step]
		case .set(let set):
			Array(repeating: [set.interval, set.recovery], count: set.repeatCount).flatMap { $0 }
		}
	}
}

extension SimpleStep {
	fileprivate func segment(in unit: WorkoutChartModel.Unit) -> WorkoutChartModel.Segment {
		let seconds = Int(
			(duration.unit == .seconds ? duration.value : duration.value * 60).rounded())
		guard let power else { return .open(durationSeconds: seconds) }
		let value = { (raw: Double) in Self.value(raw, of: power.kind, in: unit) }
		if let low = power.low, let high = power.high {
			return type == .ramp
				? .ramp(durationSeconds: seconds, start: value(low), end: value(high))
				: .range(durationSeconds: seconds, low: value(low), high: value(high))
		}
		guard let target = power.value else { return .open(durationSeconds: seconds) }
		return .steady(durationSeconds: seconds, target: value(target))
	}

	private static func value(
		_ raw: Double, of kind: PowerKind, in unit: WorkoutChartModel.Unit
	) -> Double {
		guard kind == .zone, unit == .percentOfFTP, let midpoint = ZoneMidpoints.values[Int(raw)]
		else { return raw }
		return midpoint * 100
	}
}
