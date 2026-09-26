public enum AppLifecycleEvent: Sendable, Equatable {
	case becameActive
	case willResignActive
	case enteredBackground
	case willTerminate
}
