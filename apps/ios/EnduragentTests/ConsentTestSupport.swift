import EnduragentCoach

extension CoachStatus {
	var acceptedConsent: ProviderConsent? {
		guard case .accepted(let consent) = access.consent else { return nil }
		return consent
	}
}
