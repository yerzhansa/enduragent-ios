import EnduragentCoach

enum ShellDestination: Hashable {
	case settings
	case history
	case archivedConversation(ArchivedConversationRef)
	case credits
	case accessMethod
	case modelPicker
	case training
	#if DEBUG
		case debug
		case debugCredits
		case debugRecords
		case debugLanguage
		case session
		case debugLeases
	#endif
}
