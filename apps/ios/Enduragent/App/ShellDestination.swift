import EnduragentCoach

enum ShellDestination: Hashable {
	case settings
	case history
	case archivedConversation(ArchivedConversationRef)
	case credits
	#if DEBUG
		case debug
		case debugCredits
		case debugCredentials
		case debugRecords
		case debugLanguage
		case session
		case debugLeases
	#endif
}
