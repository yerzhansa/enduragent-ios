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
		let (stream, snapshot, generation) = await statusChanges.pass {
			let snapshot = await stableStatusSnapshot()
			return (statusFeed.subscribe(from: snapshot), snapshot, trainingGeneration)
		}
		if generation == trainingGeneration {
			if trainingStatus == nil { trainingStatus = snapshot.training }
			if case .connected(let summary, _) = snapshot.training, summary.needsDisplayRead {
				startTrainingDisplay(from: summary)
			}
		}
		return stream
	}

	func publishStatus() async {
		guard statusFeed.isObserved else { return }
		let (snapshot, generation) = await statusChanges.pass {
			let snapshot = await stableStatusSnapshot()
			statusFeed.publish(snapshot)
			return (snapshot, trainingGeneration)
		}
		if generation == trainingGeneration,
			case .connected(let summary, _) = snapshot.training, summary.needsDisplayRead
		{
			startTrainingDisplay(from: summary)
		}
	}

	func invalidateTrainingDisplay() {
		trainingGeneration += 1
		trainingRefresh?.cancel()
		trainingRefresh = nil
		trainingReadID = nil
	}

	func refreshTrainingStatus() async {
		await vault.invalidateTrainingIdentity()
		invalidateTrainingDisplay()
		let generation = trainingGeneration
		let stored = await vault.storedTrainingStatus()
		guard generation == trainingGeneration else { return }
		trainingStatus = stored
		await publishStatus()
		guard generation == trainingGeneration else { return }
		guard case .connected(let summary, _) = stored else {
			for mailbox in mailboxes.values { _ = await mailbox.reviewChanged() }
			return
		}
		startTrainingDisplay(from: summary)
		await trainingRefresh?.value
		for mailbox in mailboxes.values { _ = await mailbox.reviewChanged() }
		await publishStatus()
	}

	public func retryTrainingDisplay(for connectionID: ConnectionID) async {
		if trainingReadID?.connectionID == connectionID, let refreshing = trainingRefresh {
			await refreshing.value
			return
		}
		guard case .connected(let summary, _) = trainingStatus,
			summary.connectionID == connectionID, summary.action == .retry(connectionID)
		else {
			await publishStatus()
			return
		}
		await vault.invalidateTrainingIdentity()
		invalidateTrainingDisplay()
		startTrainingDisplay(from: summary)
		await trainingRefresh?.value
	}

	func startTrainingDisplay(from summary: IntervalsSummary) {
		guard trainingRefresh == nil else { return }
		let readID = TrainingDisplayReadID(
			connectionID: summary.connectionID, generation: trainingGeneration)
		trainingReadID = readID
		trainingRefresh = Task {
			await vault.refreshTrainingDisplay(
				from: summary,
				isCurrent: { await self.isCurrentTrainingRead(readID) },
				publish: { await self.acceptTrainingDisplay($0, for: readID) })
			if isCurrentTrainingRead(readID) {
				trainingRefresh = nil
				trainingReadID = nil
			}
		}
	}

	private func isCurrentTrainingRead(_ readID: TrainingDisplayReadID) -> Bool {
		trainingGeneration == readID.generation && trainingReadID == readID
	}

	private func acceptTrainingDisplay(_ status: TrainingStatus, for readID: TrainingDisplayReadID)
		async
	{
		guard isCurrentTrainingRead(readID) else { return }
		trainingStatus = status
		await publishStatus()
	}

	private func stableStatusSnapshot() async -> CoachStatus {
		while true {
			let generation = trainingGeneration
			let snapshot = await statusSnapshot()
			if generation == trainingGeneration { return snapshot }
		}
	}

	private func statusSnapshot() async -> CoachStatus {
		let consent = await preferences.consent()
		let setup: SetupState =
			consent?.isCurrent == true
			? await vault.setup(builtInModel: builtInModel) : .needsProviderConsent
		let preferences = await preferences.load()
		let stored = await vault.storedTrainingStatus()
		let training: TrainingStatus
		if case .connected(let saved, let account) = stored,
			case .connected(let displayed, _) = trainingStatus,
			saved.connectionID == displayed.connectionID, saved.keySuffix == displayed.keySuffix,
			case .available(let checked) = saved.profile,
			case .available(let visible) = displayed.profile,
			checked.athleteID == visible.athleteID, checked.name == visible.name
		{
			training = .connected(displayed, account: account)
		} else {
			training = stored
		}
		return CoachStatus(
			setup: setup, training: training, preferences: preferences, providerConsent: consent)
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
		for mailbox in await openedMailboxes() {
			await mailbox.refreshLeaseTitle()
		}
		await publishStatus()
	}

	public func setSession(_ settings: SessionSettings) async throws(PreferenceWriteFailure) {
		try await preferences.setSession(settings)
		await publishStatus()
	}
}
