import EnduragentCoach

extension ShellModel {
	func perform(_ action: RecoveryAction) async {
		switch action {
		case .tryAgain(let turn), .wait(let turn):
			await tryAgain(turn)
		case .restoreCredits, .buyCredits:
			open(.credits)
		case .chooseAccessMethod, .signInToOpenRouter:
			route = .onboarding(.connect)
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
