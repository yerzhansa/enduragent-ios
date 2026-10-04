import EnduragentCoach

extension ShellModel {
	func perform(_ action: RecoveryAction) async {
		switch action {
		case .tryAgain(let turn), .wait(let turn):
			await tryAgain(turn)
		case .restoreCredits, .buyCredits:
			open(.credits)
		case .connectTraining:
			open(.training)
			trainingSettings.edit()
		case .signInToOpenRouter:
			guard status.access.attention == .rejectedKey else { return }
			await chooseAccess(.signInToOpenRouter)
		case .chooseAccessMethod:
			open(.accessMethod)
		}
	}

	private func tryAgain(_ turn: TurnID) async {
		do {
			try await services.coach.retry(turn, in: .main)
		} catch {
			switch error {
			case .alreadyRunning, .alreadyAnswered, .acceptedOnOtherDevice, .unknownTurn,
				.rateLimitWaitRunning, .unrecovered:
				return
			}
		}
	}
}
