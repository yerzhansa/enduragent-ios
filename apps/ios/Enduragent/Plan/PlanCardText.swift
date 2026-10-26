import EnduragentCoach

struct PlanCardText: Equatable {
	struct Pair: Equatable {
		let id: String
		let label: String
		let value: String
	}

	struct Phase: Equatable {
		let title: String
		let pairs: [Pair]
	}

	let title: String
	let preparedEarlier: String?
	let name: String
	let identity: [Pair]
	let phases: [Phase]
	let replaces: String?
	let state: String?
	let answer: String?

	init(_ card: PlanCard, answer: PlanAnswer?, in display: DisplayLocale) {
		let summary = card.summary
		title = display.say(Catalog.chatPlanSaveTitle)
		preparedEarlier =
			card.placement == .preparedEarlier ? display.say(Catalog.workoutsPreparedEarlier) : nil
		name = summary.name
		identity = [
			summary.goal.map {
				Pair(id: "goal", label: display.say(Catalog.planViewEndedGoal), value: $0)
			},
			summary.weeks.map {
				Pair(
					id: "duration", label: display.say(Catalog.chatPlanReferenceDuration),
					value: Self.weeks($0, in: display))
			},
		].compactMap(\.self)
		phases = summary.phases.enumerated().map { index, phase in
			Phase(
				title: display.say(Catalog.chatPlanSavePhase, ["number": .integer(index + 1)]),
				pairs: [
					phase.focus.map {
						Pair(
							id: "focus", label: display.say(Catalog.chatPlanSaveFocusLabel),
							value: PlanFocus(rawValue: $0).map { display.say($0.title) } ?? $0)
					},
					phase.weeks.map {
						Pair(
							id: "weeks", label: display.say(Catalog.chatPlanReferenceDuration),
							value: Self.weeks($0, in: display))
					},
					phase.hours.map {
						Pair(
							id: "hours", label: display.say(Catalog.chatPlanSaveWeeklyHours),
							value: display.number($0, precision: .compact))
					},
				].compactMap(\.self))
		}
		replaces = summary.replaces.map {
			display.say(Catalog.chatPlanSaveReplaces, ["name": .text($0)])
		}
		state = Self.stateKey(card.state).map { display.say($0) }
		self.answer = answer.flatMap { answer in
			answer.describes(card.state) ? display.say(answer.key, answer.vars) : nil
		}
	}

	private static func weeks(_ weeks: Int, in display: DisplayLocale) -> String {
		display.say(Catalog.planViewDraftWeeks, count: weeks, ["weeks": .integer(weeks)])
	}

	private static func stateKey(_ state: PlanCardState) -> CatalogKey? {
		switch state {
		case .waiting: nil
		case .saving: Catalog.chatPlanSaveSaving
		case .saved: Catalog.chatPlanSaveSaved
		case .canceled: Catalog.chatPlanSaveCanceled
		case .expired: Catalog.chatPlanSaveExpired
		case .storageUnavailable: Catalog.chatPlanSaveStorageUnavailable
		}
	}
}

enum PlanFocus: String {
	case baseBuilding = "base_building"
	case aerobicDevelopment = "aerobic_development"
	case threshold
	case vo2max
	case racePrep = "race_prep"
	case taper
	case recovery
	case maintenance
	case generalFitness = "general_fitness"

	var title: CatalogKey {
		switch self {
		case .baseBuilding: Catalog.chatPlanSaveFocusBaseBuilding
		case .aerobicDevelopment: Catalog.chatPlanSaveFocusAerobicDevelopment
		case .threshold: Catalog.chatPlanSaveFocusThreshold
		case .vo2max: Catalog.chatPlanSaveFocusVo2max
		case .racePrep: Catalog.chatPlanSaveFocusRacePrep
		case .taper: Catalog.chatPlanSaveFocusTaper
		case .recovery: Catalog.chatPlanSaveFocusRecovery
		case .maintenance: Catalog.chatPlanSaveFocusMaintenance
		case .generalFitness: Catalog.chatPlanSaveFocusGeneralFitness
		}
	}
}

enum PlanAnswer: Equatable {
	case notSaved(PlanNotSaved)
	case storageUnavailable

	init?(_ outcome: PlanDecisionOutcome) {
		switch outcome {
		case .presented, .saved, .canceled: return nil
		case .notSaved(let reason): self = .notSaved(reason)
		case .storageUnavailable: self = .storageUnavailable
		}
	}

	fileprivate func describes(_ state: PlanCardState) -> Bool {
		switch self {
		case .notSaved(.athleteChanged), .notSaved(.notPresented), .storageUnavailable:
			if case .waiting = state { true } else { false }
		case .notSaved(.alreadyDecided): [.saving, .saved, .canceled].contains(state)
		case .notSaved(.expired), .notSaved(.replaced): state == .expired
		}
	}

	fileprivate var key: CatalogKey {
		switch self {
		case .notSaved(.expired): Catalog.chatPlanSaveNotSavedExpired
		case .notSaved(.replaced): Catalog.chatPlanSaveNotSavedReplaced
		case .notSaved(.alreadyDecided): Catalog.chatPlanSaveNotSavedAlreadyDecided
		case .notSaved(.athleteChanged): Catalog.chatPlanSaveNotSavedAthleteChanged
		case .notSaved(.notPresented): Catalog.chatPlanSaveNotSavedNotPresented
		case .storageUnavailable: Catalog.chatPlanSaveStorageUnavailable
		}
	}

	fileprivate var vars: [String: CatalogArgument] {
		self == .notSaved(.athleteChanged) ? ["service": "intervals.icu"] : [:]
	}
}
