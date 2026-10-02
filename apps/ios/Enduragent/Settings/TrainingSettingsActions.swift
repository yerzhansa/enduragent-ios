import EnduragentCoach

extension ShellModel {
	func performTrainingDisplay(_ action: TrainingDisplayAction) async {
		switch action {
		case .reviewConnection:
			trainingSettings.edit()
		case .retry(let connection):
			await services.coach.retryTrainingDisplay(for: connection)
		}
	}
}
