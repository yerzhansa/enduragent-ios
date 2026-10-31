import Foundation

struct FeasibilityGoal: Sendable, Equatable {
	let currentFtp: Int
	let targetFtp: Int?
	let targetWkg: Double?
	let currentWeightKg: Double?
	let experience: ExperienceLevel
}

struct FeasibilityCheck: Sendable, Equatable {
	enum Severity: String, Sendable {
		case warning, ambitious
	}

	let severity: Severity
	let gapPercentage: Double
	let realisticMilestone: String
	let estimatedCycles: Double
	let coachMessage: String
	let enricherHint: String

	var json: JSONValue {
		.object([
			"severity": .string(severity.rawValue),
			"gapPercentage": .number(gapPercentage),
			"realisticMilestone": .string(realisticMilestone),
			"estimatedCycles": .number(estimatedCycles),
			"coachMessage": .string(coachMessage),
			"enricherHint": .string(enricherHint),
		])
	}
}

extension Planning {
	static func feasibility(_ goal: FeasibilityGoal) -> FeasibilityCheck? {
		let currentFtp = Double(goal.currentFtp)
		let thresholds = FeasibilityThresholds(goal.experience)
		if let targetWkg = goal.targetWkg, let weight = goal.currentWeightKg,
			isTruthy(targetWkg), isTruthy(weight), isTruthy(currentFtp)
		{
			guard weight > 0, currentFtp > 0 else { return nil }
			let currentWkg = currentFtp / weight
			return FeasibilityCheck(
				current: currentWkg, target: targetWkg, thresholds: thresholds,
				texts: FeasibilityTexts(
					current: JavaScriptNumber.fixed(currentWkg, digits: 1) + " W/kg",
					target: JavaScriptNumber.text(targetWkg) + " W/kg",
					milestone: { JavaScriptNumber.fixed($0, digits: 1) + " W/kg" }))
		}
		if let targetFtp = goal.targetFtp.map(Double.init), isTruthy(targetFtp),
			isTruthy(currentFtp)
		{
			guard currentFtp > 0 else { return nil }
			return FeasibilityCheck(
				current: currentFtp, target: targetFtp, thresholds: thresholds,
				texts: FeasibilityTexts(
					current: JavaScriptNumber.text(currentFtp) + "W",
					target: JavaScriptNumber.text(targetFtp) + "W",
					milestone: { JavaScriptNumber.text(JavaScriptNumber.round($0 / 5) * 5) + "W" }))
		}
		return nil
	}

	private static func isTruthy(_ value: Double) -> Bool {
		value != 0 && !value.isNaN
	}
}

private struct FeasibilityThresholds {
	let expectedGain: Double
	let warning: Double
	let ambitious: Double

	init(_ experience: ExperienceLevel) {
		switch experience {
		case .beginner: (expectedGain, warning, ambitious) = (0.25, 0.25, 0.5)
		case .intermediate: (expectedGain, warning, ambitious) = (0.2, 0.2, 0.5)
		case .advanced: (expectedGain, warning, ambitious) = (0.15, 0.15, 0.4)
		case .elite: (expectedGain, warning, ambitious) = (0.08, 0.1, 0.2)
		}
	}
}

private struct FeasibilityTexts {
	let current: String
	let target: String
	let milestone: (Double) -> String
}

extension FeasibilityCheck {
	fileprivate init?(
		current: Double, target: Double, thresholds: FeasibilityThresholds,
		texts: FeasibilityTexts
	) {
		let gapFraction = (target - current) / current
		if gapFraction <= 0 { return nil }
		if gapFraction <= thresholds.warning { return nil }
		let severity: Severity = gapFraction > thresholds.ambitious ? .ambitious : .warning
		let milestone = texts.milestone(current * (1 + thresholds.expectedGain))
		let gapPercentage = JavaScriptNumber.round(gapFraction * 100)
		let estimatedCycles = (log(target / current) / log(1 + thresholds.expectedGain))
			.rounded(.up)
		let cycles = JavaScriptNumber.text(estimatedCycles)
		self.severity = severity
		self.gapPercentage = gapPercentage
		realisticMilestone = milestone
		self.estimatedCycles = estimatedCycles
		switch severity {
		case .warning:
			coachMessage =
				"Your target of \(texts.target) is a big jump from \(texts.current). A realistic goal for this plan is around \(milestone) — think of this as the first step toward \(texts.target)."
		case .ambitious:
			let years = JavaScriptNumber.fixed(estimatedCycles * 0.33, digits: 1)
			coachMessage =
				"Going from \(texts.current) to \(texts.target) typically takes \(cycles) plan cycles (~\(years) years of consistent training). This plan will focus on building to \(milestone), setting you up for continued growth."
		}
		enricherHint =
			"The athlete targets \(texts.target) but currently benchmarks at \(texts.current). This is a \(severity.rawValue) gap (\(JavaScriptNumber.text(gapPercentage))% improvement needed). Frame this plan as the first phase of a multi-plan journey. Realistic milestone for this plan: \(milestone). Use the milestone (not the ultimate target) in the plan's primaryGoal. Acknowledge the athlete's long-term \(texts.target) target in the rationale. Estimated \(cycles) plan cycles to reach their ultimate target."
	}
}
