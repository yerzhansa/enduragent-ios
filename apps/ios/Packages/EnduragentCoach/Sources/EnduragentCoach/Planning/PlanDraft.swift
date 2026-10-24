struct ScheduleInput: Sendable, Equatable {
	let type: ScheduleType
	let availableDays: [Weekday]?
	let keySessionDay: Weekday?
	let sessionsPerWeek: Int?
}

struct GoalInput: Sendable, Equatable {
	let type: GoalType
	let raceType: RaceType?
	let raceDate: CivilDate?
	let targetTime: String?
	let generalGoal: String?
	let generalGoalTarget: String?
}

struct PlanProfile: Sendable, Equatable {
	let experience: ExperienceLevel
	let ftpWatts: Int
	let weightKg: Double?
	let volumeTier: VolumeTier
	let schedule: ScheduleInput
	let goal: GoalInput
}

struct PlanDraftOptions: Sendable, Equatable {
	let id: String
	let createdAt: String
	let totalWeeks: Int?
}

struct PlanDurationOutOfRange: Error, Sendable, Equatable {
	let totalWeeks: Int
}

struct PlanDraft: Sendable, Equatable {
	let totalWeeks: Int
	let json: JSONValue
}

extension Planning {
	static func draft(_ profile: PlanProfile, today: CivilDate, options: PlanDraftOptions)
		throws -> PlanDraft
	{
		let weeks = options.totalWeeks ?? totalWeeks(profile, today: today)
		guard (1...24).contains(weeks) else { throw PlanDurationOutOfRange(totalWeeks: weeks) }
		let zones = try DisplayZones.table(ftpWatts: profile.ftpWatts)
		let phases = DraftPhase.phases(profile, totalWeeks: weeks)
		let ratio = profile.experience.buildRecoveryRatio
		var fields: [String: JSONValue] = [
			"id": .string(options.id),
			"name": .string("\(weeks)-Week Plan"),
			"primaryGoal": .string(profile.goal.primaryGoal),
			"totalWeeks": .number(Double(weeks)),
			"cycleLength": .number(Double(DraftPhase.cycleLength)),
			"cycleStructureDescription": .string(
				"\(DraftPhase.cycleLength)-day cycles with \(ratio.build):\(ratio.recovery) build/recovery"
			),
			"phases": .array(phases.map(\.json)),
			"zoneTables": .array([
				.object([
					"sport": .string("cycling"),
					"zones": .array(
						zones.map { row in
							.object([
								"name": .string(row.label),
								"range": .string(row.value),
								"description": .string(zoneDescription(row.label)),
							])
						}),
				])
			]),
			"progressions": .array([]),
			"testingProtocols": .array(testingProtocols(phases)),
			"volumeSummary": volumeSummary(phases),
			"schedulePreferences": profile.schedule.json,
			"createdAt": .string(options.createdAt),
			"updatedAt": .string(options.createdAt),
			"status": .string("draft"),
		]
		if let raceDate = profile.goal.raceDate {
			fields["targetDate"] = .string("\(raceDate.rawValue)T00:00:00.000Z")
		}
		return PlanDraft(totalWeeks: weeks, json: .object(fields))
	}

	private static func zoneDescription(_ label: String) -> String {
		switch label {
		case "Z1 Active Recovery": "Very light spinning for recovery"
		case "Z2 Endurance": "Aerobic base building, conversational pace"
		case "Z3 Tempo": "Moderate effort, sustainable for 1-2 hours"
		case "Sweet Spot (88-94%)": "High aerobic stress, efficient training sub-range"
		case "Z4 Threshold": "Lactate threshold, ~1 hour effort"
		case "Z5 VO2max": "High intensity intervals, 3-8 minute efforts"
		default: "Training zone"
		}
	}

	private static func testingProtocols(_ phases: [DraftPhase]) -> [JSONValue] {
		let totalCycles = phases.reduce(0) { $0 + $1.cycles }
		if totalCycles == 0 { return [] }
		var checkpoints = Array(stride(from: 4, through: totalCycles, by: 4))
		if checkpoints.isEmpty { checkpoints = [totalCycles] }
		return [
			.object([
				"frequency": .string("Every 4 weeks"),
				"method": .string("20-minute FTP test"),
				"checkpoints": .array(
					checkpoints.map { cycle in
						.object([
							"cycle": .number(Double(cycle)),
							"expectedValue": .string("TBD"),
						])
					}),
			])
		]
	}

	private static func volumeSummary(_ phases: [DraftPhase]) -> JSONValue {
		var totalPlanHours = 0.0
		let byPhase = phases.map { phase in
			let hours = max(0.1, JavaScriptNumber.roundToTenths(phase.hours * Double(phase.cycles)))
			totalPlanHours += hours
			return JSONValue.object([
				"phaseName": .string(phase.name),
				"phaseNumber": .number(Double(phase.number)),
				"totalHours": .number(hours),
				"hours": .number(hours),
			])
		}
		return .object([
			"byPhase": .array(byPhase),
			"totalPlanHours": .number(max(0.1, JavaScriptNumber.roundToTenths(totalPlanHours))),
			"intensityDistribution": .string(
				phases.first?.focus.intensityDistribution ?? "80% easy / 20% moderate"),
		])
	}
}

private struct DraftPhase {
	static let cycleLength = 7

	let number: Int
	let weeks: Int
	let focus: PhaseFocus
	let sessions: Int
	let hours: Double

	var name: String { "Phase \(number)" }

	var cycles: Int { (weeks * 7 + Self.cycleLength - 1) / Self.cycleLength }

	var json: JSONValue {
		.object([
			"number": .number(Double(number)),
			"name": .string(name),
			"durationWeeks": .number(Double(weeks)),
			"durationCycles": .number(Double(cycles)),
			"focus": .string(focus.rawValue),
			"volumeTargets": .object([
				"cycling": .object([
					"sessionsPerCycle": .number(Double(sessions)),
					"hoursPerCycle": .number(hours),
				])
			]),
			"keyAdditions": .array([]),
		])
	}

	static func phases(_ profile: PlanProfile, totalWeeks: Int) -> [DraftPhase] {
		let taperWeeks =
			profile.goal.type == .race
			? profile.goal.raceType.map { min(totalWeeks, $0.taperWeeks) } ?? 0 : 0
		let remainingWeeks = totalWeeks - taperWeeks
		let templates = Array(
			PeriodizationModel(profile, totalWeeks: totalWeeks).templates.prefix(remainingWeeks))
		let weeks = distribute(templates.map { $0.share * Double(remainingWeeks) }, remainingWeeks)
		let hasTaper = taperWeeks > 0
		let volume = PhaseVolume(
			tier: profile.volumeTier, totalPhases: templates.count + (hasTaper ? 1 : 0),
			hasTaper: hasTaper, maxSessions: profile.schedule.maxSessions)
		var phases = templates.enumerated().map { index, template in
			volume.phase(index, weeks: weeks[index], focus: template.focus)
		}
		if hasTaper {
			phases.append(volume.phase(phases.count, weeks: taperWeeks, focus: .taper))
		}
		return phases
	}

	private static func distribute(_ rawWeeks: [Double], _ total: Int) -> [Int] {
		if total == 0 || rawWeeks.isEmpty { return [] }
		var rounded = rawWeeks.map { max(1, Int(JavaScriptNumber.round($0))) }
		var sum = rounded.reduce(0, +)
		while sum > total {
			guard let largest = rounded.max(), let index = rounded.firstIndex(of: largest),
				largest > 1
			else { break }
			rounded[index] -= 1
			sum -= 1
		}
		while sum < total {
			guard let smallest = rounded.min(), let index = rounded.firstIndex(of: smallest)
			else { break }
			rounded[index] += 1
			sum += 1
		}
		return rounded
	}
}

private struct PhaseVolume {
	let tier: VolumeTier
	let totalPhases: Int
	let hasTaper: Bool
	let maxSessions: Int?

	func phase(_ index: Int, weeks: Int, focus: PhaseFocus) -> DraftPhase {
		let multiplier = multiplier(index)
		let range = tier.weeklyRange
		let baseSessions = JavaScriptNumber.round(
			Double(range.sessions.min + range.sessions.max) / 2)
		let baseHours = Double(range.hours.min + range.hours.max) / 2
		var sessions = max(1, Int(JavaScriptNumber.round(baseSessions * multiplier)))
		if let maxSessions { sessions = min(sessions, maxSessions) }
		return DraftPhase(
			number: index + 1, weeks: weeks, focus: focus, sessions: sessions,
			hours: JavaScriptNumber.roundToTenths(baseHours * multiplier))
	}

	private func multiplier(_ index: Int) -> Double {
		if index == totalPhases - 1 && totalPhases > 1 { return hasTaper ? 0.6 : 1.15 }
		if index == totalPhases - 2 && totalPhases > 2 { return 1.15 }
		if index == 0 { return 1.0 }
		return 1.1
	}
}

private enum PhaseFocus: String {
	case baseBuilding = "base_building"
	case aerobicDevelopment = "aerobic_development"
	case threshold
	case vo2max
	case racePrep = "race_prep"
	case taper

	var intensityDistribution: String {
		switch self {
		case .baseBuilding: "85% easy / 10% tempo / 5% threshold"
		case .aerobicDevelopment: "80% easy / 15% tempo / 5% threshold"
		case .threshold: "70% easy / 20% threshold / 10% VO2max"
		case .vo2max: "65% easy / 15% threshold / 20% VO2max"
		case .racePrep: "60% easy / 25% race-pace / 15% VO2max"
		case .taper: "85% easy / 15% light efforts"
		}
	}
}

private enum PeriodizationModel {
	case linear, block, reverseLinear, polarized, pyramidal

	init(_ profile: PlanProfile, totalWeeks: Int) {
		let experience = profile.experience
		if experience == .beginner {
			self = .linear
		} else if totalWeeks <= 8 {
			self = .reverseLinear
		} else if experience == .advanced || experience == .elite, profile.volumeTier == .high {
			self = .polarized
		} else if experience == .intermediate, profile.goal.type == .race {
			self = .block
		} else {
			self = .pyramidal
		}
	}

	var templates: [(focus: PhaseFocus, share: Double)] {
		switch self {
		case .linear: [(.baseBuilding, 0.45), (.threshold, 0.35), (.racePrep, 0.2)]
		case .block:
			[(.aerobicDevelopment, 0.3), (.threshold, 0.3), (.vo2max, 0.25), (.racePrep, 0.15)]
		case .reverseLinear: [(.vo2max, 0.45), (.aerobicDevelopment, 0.35), (.racePrep, 0.2)]
		case .polarized: [(.aerobicDevelopment, 0.4), (.baseBuilding, 0.35), (.threshold, 0.25)]
		case .pyramidal:
			[
				(.baseBuilding, 0.35), (.aerobicDevelopment, 0.3), (.threshold, 0.2),
				(.racePrep, 0.15),
			]
		}
	}
}

extension ExperienceLevel {
	fileprivate var buildRecoveryRatio: (build: Int, recovery: Int) {
		switch self {
		case .beginner: (2, 1)
		case .intermediate, .advanced: (3, 1)
		case .elite: (4, 1)
		}
	}
}

extension VolumeTier {
	fileprivate var weeklyRange: (hours: (min: Int, max: Int), sessions: (min: Int, max: Int)) {
		switch self {
		case .low: ((4, 6), (3, 3))
		case .medium: ((7, 10), (4, 5))
		case .high: ((11, 15), (5, 6))
		}
	}
}

extension RaceType {
	fileprivate var taperWeeks: Int {
		switch self {
		case .century, .granFondo: 2
		case .criterium, .timeTrial, .other: 1
		}
	}
}

extension GoalInput {
	fileprivate var primaryGoal: String {
		switch type {
		case .race:
			let time = targetTime.flatMap { $0.isEmpty ? nil : " in \($0)" } ?? ""
			return (raceType?.rawValue ?? "race") + time
		case .general:
			return generalGoal ?? "General fitness improvement"
		}
	}
}

extension ScheduleInput {
	fileprivate var maxSessions: Int? {
		if type == .fixed, let availableDays, !availableDays.isEmpty { return availableDays.count }
		return sessionsPerWeek
	}

	fileprivate var json: JSONValue {
		var fields: [String: JSONValue] = ["scheduleType": .string(type.rawValue)]
		if let availableDays {
			fields["availableDays"] = .array(availableDays.map { .string($0.rawValue) })
		}
		if let keySessionDay { fields["keySessionDay"] = .string(keySessionDay.rawValue) }
		if let sessionsPerWeek { fields["sessionsPerWeek"] = .number(Double(sessionsPerWeek)) }
		return .object(fields)
	}
}
