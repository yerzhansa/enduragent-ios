import Foundation

extension GatedToolInputPayload {
	init(_ input: GatedToolInput) {
		switch input {
		case .createWorkout(let date, let workout):
			self = .createWorkout(date: date.rawValue, workout: WorkoutPayload(workout))
		case .createStrengthWorkout(let date, let name, let description):
			self = .createStrengthWorkout(date: date.rawValue, name: name, description: description)
		case .deleteWorkout(let eventId):
			self = .deleteWorkout(eventId: eventId.rawValue)
		case .updateWorkout(let input):
			self = .updateWorkout(
				eventId: input.eventId.rawValue,
				date: input.date?.rawValue,
				name: input.name,
				description: input.description
			)
		case .planSave(let headline):
			self = .planSave(
				name: headline.name,
				primaryGoal: headline.primaryGoal,
				totalWeeks: headline.totalWeeks,
				status: headline.status?.rawValue
			)
		}
	}

	func gatedToolInput() throws -> GatedToolInput {
		switch self {
		case .createWorkout(let date, let workout):
			return .createWorkout(date: try decodeCivilDate(date), workout: try workout.workout())
		case .createStrengthWorkout(let date, let name, let description):
			return .createStrengthWorkout(
				date: try decodeCivilDate(date), name: name, description: description)
		case .deleteWorkout(let eventId):
			return .deleteWorkout(eventId: EventID(rawValue: eventId))
		case .updateWorkout(let eventId, let date, let name, let description):
			return .updateWorkout(
				UpdateWorkoutInput(
					eventId: EventID(rawValue: eventId),
					date: try date.map(decodeCivilDate),
					name: name,
					description: description
				)
			)
		case .planSave(let name, let primaryGoal, let totalWeeks, let status):
			let parsedStatus: PlanStatus?
			if let status {
				guard let value = PlanStatus(rawValue: status) else {
					throw RecordDecodeFailure(reason: "planSave")
				}
				parsedStatus = value
			} else {
				parsedStatus = nil
			}
			return .planSave(
				PlanHeadline(
					name: name, primaryGoal: primaryGoal, totalWeeks: totalWeeks,
					status: parsedStatus)
			)
		}
	}
}

extension WorkoutPayload {
	init(_ workout: IntervalsWorkoutInput) {
		self.init(name: workout.name, steps: workout.steps.map(StepPayload.init))
	}

	func workout() throws -> IntervalsWorkoutInput {
		IntervalsWorkoutInput(name: name, steps: try steps.map { try $0.step() })
	}
}

extension StepPayload {
	init(_ step: WorkoutStep) {
		switch step {
		case .simple(let simple):
			self = .simple(SimpleStepPayload(simple))
		case .set(let set):
			self = .set(SetStepPayload(set))
		}
	}

	func step() throws -> WorkoutStep {
		switch self {
		case .simple(let payload):
			return .simple(try payload.simpleStep())
		case .set(let payload):
			return .set(try payload.setStep())
		}
	}
}

extension SimpleStepPayload {
	init(_ step: SimpleStep) {
		self.init(
			type: step.type.rawValue,
			duration: DurationPayload(
				value: step.duration.value, unit: step.duration.unit.rawValue),
			power: step.power.map {
				PowerPayload(kind: $0.kind.rawValue, value: $0.value, low: $0.low, high: $0.high)
			},
			cadence: step.cadence.map {
				CadencePayload(value: $0.value, low: $0.low, high: $0.high)
			},
			label: step.label
		)
	}

	func simpleStep() throws -> SimpleStep {
		guard let type = StepType(rawValue: type),
			let unit = DurationInput.Unit(rawValue: duration.unit)
		else {
			throw RecordDecodeFailure(reason: "step")
		}
		let power: PowerTarget?
		if let payload = self.power {
			guard let kind = PowerKind(rawValue: payload.kind) else {
				throw RecordDecodeFailure(reason: "power")
			}
			power = PowerTarget(
				kind: kind, value: payload.value, low: payload.low, high: payload.high)
		} else {
			power = nil
		}
		return SimpleStep(
			type: type,
			duration: DurationInput(value: duration.value, unit: unit),
			power: power,
			cadence: cadence.map { CadenceTarget(value: $0.value, low: $0.low, high: $0.high) },
			label: label
		)
	}
}

extension SetStepPayload {
	init(_ step: SetStep) {
		self.init(
			repeatCount: step.repeatCount,
			interval: SimpleStepPayload(step.interval),
			recovery: SimpleStepPayload(step.recovery)
		)
	}

	func setStep() throws -> SetStep {
		SetStep(
			repeatCount: repeatCount, interval: try interval.simpleStep(),
			recovery: try recovery.simpleStep())
	}
}

func decodeChatID(_ raw: String) throws -> ChatID {
	guard let value = ChatID(rawValue: raw) else {
		throw RecordDecodeFailure(reason: "chatId")
	}
	return value
}

func decodeULID(_ raw: String) throws -> ULID {
	guard let value = ULID(rawValue: raw) else {
		throw RecordDecodeFailure(reason: "ulid")
	}
	return value
}

func decodeCivilDate(_ raw: String) throws -> CivilDate {
	guard let value = CivilDate(rawValue: raw) else {
		throw RecordDecodeFailure(reason: "civilDate")
	}
	return value
}

func decodeSlash(_ raw: String) throws -> SlashCommand {
	guard let value = SlashCommand(rawValue: raw) else {
		throw RecordDecodeFailure(reason: "slash")
	}
	return value
}

extension RecordKind: CaseIterable {
	public static var allCases: [RecordKind] {
		[
			.userMessage, .assistantMessage, .windowStart, .compactionSummary, .memorySection,
			.dailyNote,
			.ledgerEvent, .journal, .provenance, .pendingProposal, .proposalCleared, .flushPending,
			.coachReplyLanguage, .planningDevice, .planningCommand, .planRevision, .mirrorJob,
			.workoutMatch,
			.workoutDrift,
		]
	}
}
