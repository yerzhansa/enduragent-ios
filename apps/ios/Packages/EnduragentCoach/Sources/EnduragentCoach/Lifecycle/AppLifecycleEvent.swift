public enum AppLifecycleEvent: Sendable, Equatable {
	case becameActive
	case enteredBackground
	case willTerminate
}
