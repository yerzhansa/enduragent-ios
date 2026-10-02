import Foundation

extension Coach {
	public func changeModelAccess(_ change: ModelAccessChange) async
		-> CredentialOutcome<AccessSummary>
	{
		let outcome = await vault.change(change)
		await publishStatus()
		return outcome
	}

	public func creditsIdentity() async throws(AccessUnavailable) -> CreditsIdentity {
		try await vault.creditsIdentity()
	}

	public func prepareCreditsPurchase() async throws(AccessUnavailable) -> UUID {
		try await vault.prepareCreditsAccount()
	}

	public func observeStatus() async -> AsyncStream<CoachStatus> {
		observeImports()
		return await statusChanges.pass {
			await statusFeed.subscribe(from: statusSnapshot())
		}
	}

	func publishStatus() async {
		guard statusFeed.isObserved else { return }
		await statusChanges.pass {
			await statusFeed.publish(statusSnapshot())
		}
	}

	func refreshTrainingStatus() async {
		await publishStatus()
		let refreshing = trainingRefresh ?? Task { await vault.trainingStatus() }
		trainingRefresh = refreshing
		let refreshed = await refreshing.value
		guard trainingRefresh == refreshing else { return }
		trainingRefresh = nil
		trainingStatus = refreshed
		await publishStatus()
	}

	private func statusSnapshot() async -> CoachStatus {
		let consent = await preferences.consent()
		let setup: SetupState =
			consent?.isCurrent == true
			? await vault.setup(builtInModel: builtInModel) : .needsProviderConsent
		let training: TrainingStatus
		if let trainingStatus {
			training = trainingStatus
		} else {
			training = await vault.storedTrainingStatus()
		}
		return CoachStatus(
			setup: setup, training: training, preferences: await preferences.load(),
			providerConsent: consent)
	}

	public func languagePreference() async -> LanguagePreference {
		await preferences.load().language
	}

	public func recordConsent() async throws(PreferenceWriteFailure) {
		try await preferences.recordConsent()
		await publishStatus()
	}

	public func setLanguage(_ preference: LanguagePreference) async throws(PreferenceWriteFailure) {
		try await preferences.setLanguage(preference)
		await publishStatus()
	}

	public func setSession(_ settings: SessionSettings) async throws(PreferenceWriteFailure) {
		try await preferences.setSession(settings)
		await publishStatus()
	}
}
