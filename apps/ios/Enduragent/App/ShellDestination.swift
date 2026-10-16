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
	#if DEBUG
		case debug
		case debugCredits
		case debugRecords
		case debugLanguage
		case debugLeases
	#endif
}
