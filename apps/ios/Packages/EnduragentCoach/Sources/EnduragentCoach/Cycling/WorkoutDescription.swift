import Foundation

extension IntervalsSerializer {
	package static func description(
		_ workout: IntervalsWorkoutInput, display: DisplayLocale? = nil
	) -> [String] {
		var lines: [String] = []
		var currentLabel: String?
		for step in workout.steps {
			let label = sectionLabel(step, phrasebook: display?.phrasebook)
			if label != currentLabel {
				if !lines.isEmpty { lines.append("") }
				lines.append(label)
				currentLabel = label
			}
			switch step {
			case .set(let set):
				lines.append("\(set.repeatCount)x")
				lines.append(stepLine(set.interval, display: display))
				lines.append(stepLine(set.recovery, display: display))
			case .simple(let simple):
				lines.append(stepLine(simple, display: display))
			}
		}
		return lines
	}

	private static func sectionLabel(_ step: WorkoutStep, phrasebook: CatalogPhrasebook?) -> String
	{
		if case .simple(let simple) = step {
			if simple.type == .warmup {
				return phrasebook?.say(Catalog.reviewWorkoutWarmup, [:]) ?? "Warmup"
			}
			if simple.type == .cooldown {
				return phrasebook?.say(Catalog.reviewWorkoutCooldown, [:]) ?? "Cooldown"
			}
		}
		return phrasebook?.say(Catalog.reviewWorkoutMainSet, [:]) ?? "Main set"
	}

	private static func stepLine(_ step: SimpleStep, display: DisplayLocale?) -> String {
		var parts = [formatDuration(step.duration)]
		if let power = step.power {
			let target = powerText(power, ramp: step.type == .ramp, display: display)
			parts.append(
				step.type == .ramp
					? "\(display?.phrasebook.say(Catalog.reviewWorkoutRamp, [:]) ?? "ramp") \(target)"
					: target)
		}
		if let cadence = step.cadence {
			if let low = cadence.low, let high = cadence.high {
				parts.append("\(low)-\(high)rpm")
			} else if let value = cadence.value {
				parts.append("\(value)rpm")
			}
		}
		if let label = step.label { parts.append(label) }
		return "- " + parts.joined(separator: " ")
	}

	private static func powerText(
		_ power: PowerTarget, ramp: Bool, display: DisplayLocale?
	) -> String {
		let number = { (value: Double) in
			display?.number(value, precision: .compact) ?? jsString(value)
		}
		if let low = power.low, let high = power.high {
			switch power.kind {
			case .zone:
				if ramp { return "\(zonePercent(low))-\(zonePercent(high))%" }
				return "Z\(number(low))-Z\(number(high))"
			case .percentFtp: return "\(number(low))-\(number(high))%"
			case .watts: return "\(number(low))-\(number(high))w"
			}
		}
		guard let value = power.value else {
			preconditionFailure("Workout power must be validated before rendering")
		}
		switch power.kind {
		case .zone: return "Z\(number(value))"
		case .percentFtp: return "\(number(value))%"
		case .watts: return "\(number(value))w"
		}
	}

	private static func zonePercent(_ zone: Double) -> Int {
		guard let midpoint = ZoneMidpoints.values[Int(zone)] else {
			preconditionFailure("Workout zone must be validated before rendering")
		}
		return Int((midpoint * 100).rounded())
	}
}
