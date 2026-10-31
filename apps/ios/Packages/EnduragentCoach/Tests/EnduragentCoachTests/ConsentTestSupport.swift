import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

let testConsentTarget: ConsentTarget = {
	guard let entry = ModelCatalog.fixture.orderedEntries.first else {
		preconditionFailure("The fixture catalog must have a built-in model")
	}
	return ConsentTarget(method: .credits, entry: entry)
}()

extension Coach {
	func recordConsent() async throws {
		let consent = await vault.accessConsent(builtInModel: builtInModel, recorded: nil)
		if case .accepted = consent { return }
		guard case .required(let challenge) = consent else {
			throw ConsentWriteFailure.staleChallenge
		}
		try await recordConsent(challenge)
	}
}

extension CoachStatus {
	var acceptedConsent: ProviderConsent? {
		guard case .accepted(let consent) = access.consent else { return nil }
		return consent
	}
}
