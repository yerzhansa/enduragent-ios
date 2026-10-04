import Foundation

extension Coach {
	public func recordConsent(_ challenge: ConsentChallenge) async throws(ConsentWriteFailure) {
		do {
			try await vault.validateConsent(challenge, builtInModel: builtInModel)
			try await preferences.recordConsent(challenge.target)
			try await vault.finishConsent(challenge, builtInModel: builtInModel)
		} catch {
			await publishStatus()
			throw error
		}
		await publishStatus()
	}

	public func declineConsent(_ challenge: ConsentChallenge) async {
		await vault.declineConsent(challenge)
		await publishStatus()
	}
}
