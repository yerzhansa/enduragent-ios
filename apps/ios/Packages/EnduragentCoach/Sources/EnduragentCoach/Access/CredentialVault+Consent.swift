import Foundation

extension CredentialVault {
	func consentTarget(builtInModel: ModelID) throws(AccessUnavailable) -> ConsentTarget {
		ConsentTarget(method: .credits, entry: try builtInEntry(builtInModel))
	}

	func accessConsent(builtInModel: ModelID, recorded: ProviderConsent?) -> AccessConsent {
		do {
			let target = try consentTarget(builtInModel: builtInModel)
			if let recorded, recorded.authorizes(target) { return .accepted(recorded) }
			if let consentChallenge, consentChallenge.target == target {
				return .required(consentChallenge)
			}
			let challenge = ConsentChallenge(target: target, generation: UUID())
			consentChallenge = challenge
			return .required(challenge)
		} catch {
			consentChallenge = nil
			return .unavailable
		}
	}

	func validateConsent(_ challenge: ConsentChallenge, builtInModel: ModelID)
		throws(ConsentWriteFailure)
	{
		guard
			case .required(let current) = accessConsent(builtInModel: builtInModel, recorded: nil),
			current == challenge
		else { throw .staleChallenge }
	}

	func finishConsent(_ challenge: ConsentChallenge) {
		if consentChallenge == challenge { consentChallenge = nil }
	}

	func requestTarget(_ request: CompletionRequest) throws(AccessUnavailable) -> ConsentTarget {
		do {
			let entry = try ModelCatalogEntry(
				id: request.model,
				details: ModelDetails(
					displayName: request.model.rawValue, provider: request.provider))
			return ConsentTarget(method: request.credential.method, entry: entry)
		} catch {
			throw .malformedStoredCredential(.accessSelection)
		}
	}
}
