import Foundation

package struct LegacyProposalBody: Sendable, Equatable {
	package let chatId: ChatID
	package let nonce: Nonce
	package let writeID: CalendarWriteID?
	package let change: LegacyCalendarChange
	package let expiresAt: Date

	package init(
		chatId: ChatID, nonce: Nonce, writeID: CalendarWriteID?, change: LegacyCalendarChange,
		expiresAt: Date
	) {
		self.chatId = chatId
		self.nonce = nonce
		self.writeID = writeID
		self.change = change
		self.expiresAt = expiresAt
	}
}

package enum LegacyCalendarChange: Sendable, Equatable {
	case add(CalendarPayload)
	case edit(EventID, WorkoutPatch)
	case delete(EventID)
}

struct ProposalPayload: Decodable {
	var writeID: UUID?
	var chatId: String
	var nonce: UUID
	var toolInput: ProposalInputPayload
	var expiresAt: TimeInterval

	func body() throws -> LegacyProposalBody {
		LegacyProposalBody(
			chatId: try decodeChatID(chatId), nonce: Nonce(rawValue: nonce),
			writeID: writeID.map(CalendarWriteID.init(rawValue:)), change: try toolInput.change(),
			expiresAt: Date(timeIntervalSince1970: expiresAt))
	}
}

struct ProposalClearedPayload: Decodable {
	var chatId: String
	var nonce: UUID
}

enum ProposalInputPayload: Decodable {
	case createWorkout(date: String, workout: WorkoutPayload)
	case createStrengthWorkout(date: String, name: String, description: String)
	case deleteWorkout(eventId: Int)
	case updateWorkout(eventId: Int, date: String?, name: String?, description: String?)

	func change() throws -> LegacyCalendarChange {
		switch self {
		case .createWorkout(let date, let workout):
			let ride = try workout.workout()
			return .add(
				CalendarPayload(
					date: try decodeCivilDate(date), type: .ride, name: ride.name,
					description: try IntervalsSerializer.serialize(ride).description,
					movingTime: nil, trainingLoad: nil, authoredSteps: nil))
		case .createStrengthWorkout(let date, let name, let description):
			return .add(
				CalendarPayload(
					date: try decodeCivilDate(date), type: .weightTraining, name: name,
					description: description, movingTime: nil, trainingLoad: nil,
					authoredSteps: nil))
		case .deleteWorkout(let eventId):
			return .delete(EventID(rawValue: eventId))
		case .updateWorkout(let eventId, let date, let name, let description):
			return .edit(
				EventID(rawValue: eventId),
				WorkoutPatch(
					date: try date.map(decodeCivilDate), name: name, durationSeconds: nil,
					description: description, trainingLoad: nil, workoutDocument: nil,
					authoredSteps: nil))
		}
	}
}

struct DurationPayload: Decodable {
	var value: Double
	var unit: String
}

struct PowerPayload: Decodable {
	var kind: String
	var value: Double?
	var low: Double?
	var high: Double?
}

struct CadencePayload: Decodable {
	var value: Int?
	var low: Int?
	var high: Int?
}

struct SimpleStepPayload: Decodable {
	var type: String
	var duration: DurationPayload
	var power: PowerPayload?
	var cadence: CadencePayload?
	var label: String?
}

struct SetStepPayload: Decodable {
	var repeatCount: Int
	var interval: SimpleStepPayload
	var recovery: SimpleStepPayload
}

enum StepPayload: Decodable {
	case simple(SimpleStepPayload)
	case set(SetStepPayload)
}

struct WorkoutPayload: Decodable {
	var name: String
	var steps: [StepPayload]
}

extension WorkoutPayload {
	func workout() throws -> IntervalsWorkoutInput {
		let workout = IntervalsWorkoutInput(name: name, steps: try steps.map { try $0.step() })
		try IntervalsSerializer.validate(workout)
		return workout
	}
}

extension StepPayload {
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
	func setStep() throws -> SetStep {
		SetStep(
			repeatCount: repeatCount, interval: try interval.simpleStep(),
			recovery: try recovery.simpleStep())
	}
}
