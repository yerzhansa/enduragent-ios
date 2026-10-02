import EnduragentCoach
import Observation

@MainActor
@Observable
final class TrainingSettingsModel {
	enum State: Equatable {
		case viewing
		case editing
		case saving
		case savingAway
		case confirmingOwner(apiKey: String, current: IntervalsAthleteID, new: IntervalsAthleteID)
		case confirmingDisconnect
	}

	var key = ""
	private(set) var state: State = .viewing
	private(set) var receipt: CredentialOutcome<IntervalsSummary>?
	private let coach: Coach

	init(coach: Coach) {
		self.coach = coach
	}

	var isSaving: Bool { state == .saving || state == .savingAway }
	var isEditing: Bool { state == .editing }

	func edit() {
		guard !isSaving else { return }
		key = ""
		receipt = nil
		state = .editing
	}

	func keep() async {
		guard !isSaving else { return }
		key = ""
		await change(.keep)
	}

	func replace() async {
		guard isEditing else { return }
		await change(.replace(apiKey: key, athlete: .keyOwner))
	}

	func requestDisconnect() {
		guard !isSaving else { return }
		key = ""
		state = .confirmingDisconnect
	}

	func confirm() async {
		switch state {
		case .confirmingOwner(let apiKey, _, _):
			await change(.replaceConfirmingAthleteSwitch(apiKey: apiKey, athlete: .keyOwner))
		case .confirmingDisconnect:
			await change(.disconnect)
		case .viewing, .editing, .saving, .savingAway:
			return
		}
	}

	func dismiss() {
		key = ""
		receipt = nil
		state = isSaving ? .savingAway : .viewing
	}

	private func change(_ intent: IntervalsConnectionChange) async {
		let submittedKey: String
		switch intent {
		case .replace(let apiKey, _), .replaceConfirmingAthleteSwitch(let apiKey, _):
			submittedKey = apiKey
		case .keep, .disconnect: submittedKey = ""
		}
		state = .saving
		let result = await coach.changeTraining(intent)
		guard state == .saving else {
			key = ""
			state = .viewing
			return
		}
		receipt = result
		switch result {
		case .refused(.differentAthlete(let current, let new)):
			state = .confirmingOwner(apiKey: submittedKey, current: current, new: new)
			key = ""
		case .refused, .failedPreviousKept:
			key = submittedKey
			state = .editing
		case .kept, .replaced, .disconnected:
			key = ""
			state = .viewing
		}
	}
}
