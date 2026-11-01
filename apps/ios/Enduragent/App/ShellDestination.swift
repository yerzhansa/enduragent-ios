import EnduragentCoach

enum ShellDestination: Hashable {
	case settings
	case history
	case archivedConversation(ArchivedConversationRef)
	case credits
	case accessMethod
	case modelPicker
	case training
	case session
	case feedback
	case diagnostics
	case about
	case yourData
	#if DEBUG
		case debug
		case debugCredits
		case debugRecords
		case debugLanguage
		case debugLeases
	#endif
}
