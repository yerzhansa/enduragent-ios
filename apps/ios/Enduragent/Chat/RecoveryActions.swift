import EnduragentCoach

extension ShellModel {
	func perform(_ action: RecoveryAction) async {
		switch action {
		case .tryAgain(let turn), .wait(_, let turn):
			await tryAgain(turn)
		case .restoreCredits, .buyCredits:
			showCredits = true
		case .chooseAccessMethod, .signInToOpenRouter:
			route = .onboarding(.connect)
		}
	}

	private func tryAgain(_ turn: TurnID) async {
		guard let services else { return }
		if let text = chat?.turns.first(where: { $0.id == turn })?.athleteText {
			services.fixtureDirector?.prepareRetry(of: text)
		}
		do {
			try await services.coach.retry(turn, in: chatId)
		} catch {
			switch error {
			case .alreadyRunning, .alreadyAnswered, .acceptedOnOtherDevice, .unknownTurn:
				return
			}
		}
	}
}
