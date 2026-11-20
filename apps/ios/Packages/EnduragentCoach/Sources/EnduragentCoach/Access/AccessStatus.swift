public enum AccessAvailability: Equatable, Sendable {
	case ready
	case needsSetup
	case unavailable(AccessUnavailable)
}

public struct AccessStatus: Equatable, Sendable {
	public let availability: AccessAvailability
	public let model: ModelID
	public let consent: AccessConsent

	package init(
		availability: AccessAvailability, model: ModelID, consent: AccessConsent = .unavailable
	) {
		self.availability = availability
		self.model = model
		self.consent = consent
	}
}
