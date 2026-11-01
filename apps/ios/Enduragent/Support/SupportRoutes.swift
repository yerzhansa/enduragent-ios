import EnduragentCoach

extension ShellModel {
	func follow(_ outcome: SendOutcome?) {
		switch outcome {
		case .showLanguagePicker:
			openLanguagePicker()
		case .openScreen(.feedback, let argument):
			support.prefill(argument)
			open(.feedback)
		case .openScreen(.about, _):
			open(.about)
		case .accepted, .newConversation, .ignoredBlank, nil:
			break
		}
	}
}
