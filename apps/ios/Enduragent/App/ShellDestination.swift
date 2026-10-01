enum ShellDestination: Hashable {
	case settings
	case history
	case credits
	#if DEBUG
		case debug
		case session
	#endif

	var path: [Self] {
		switch self {
		case .settings, .history: [self]
		case .credits: [.settings, .credits]
		#if DEBUG
			case .debug: [.settings, .debug]
			case .session: [.settings, .debug, .session]
		#endif
		}
	}
}
