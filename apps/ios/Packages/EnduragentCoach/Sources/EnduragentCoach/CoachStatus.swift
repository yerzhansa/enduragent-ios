import Foundation

extension Coach {
	public func observeStatus() async -> AsyncStream<CoachStatus> {
		await statusChanges.pass {
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
		let consent = await providerConsent()
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
			setup: setup, training: training, preferences: await loadedPreferences(),
			providerConsent: consent)
	}

	public func languagePreference() async -> LanguagePreference {
		await loadedPreferences().language
	}

	public func recordConsent() async throws(PreferenceWriteFailure) {
		guard await providerConsent()?.isCurrent != true else {
			await publishStatus()
			return
		}
		let stamp = OperationStamp(
			operation: .preferenceChange(PreferenceChangeID(ulid: await ledger.nextULID())),
			attempt: AttemptID(ulid: await ledger.nextULID()), binding: binding)
		do {
			_ = try await ledger.commit(
				local: [.providerConsent(ProviderConsent(at: clock.now))], stamp: stamp)
		} catch {
			throw .notSaved
		}
		await publishStatus()
	}

	func providerConsent() async -> ProviderConsent? {
		do {
			let page = try await ledger.read(
				RecordQuery(scope: .deviceLocal([.providerConsent]), writtenBy: ledger.deviceId))
			guard case .deviceLocal(.providerConsent(let consent)) = page.records.last?.body
			else { return nil }
			return consent
		} catch {
			diagnostics.record(.preferencesUnavailable(error))
			return nil
		}
	}

	public func setLanguage(_ preference: LanguagePreference) async throws(PreferenceWriteFailure) {
		guard await loadedPreferences().language != preference else {
			await publishStatus()
			return
		}
		try await commitPreference(
			.languagePreference(LanguagePreferenceBody(preference: preference)))
	}

	public func setSession(_ settings: SessionSettings) async throws(PreferenceWriteFailure) {
		try await commitPreference(.sessionSettings(SessionSettingsBody(settings: settings)))
	}

	private var binding: ActionBinding {
		ActionBinding(account: .unconnected, zone: AthleteCalendar(clock: clock).deviceZone)
	}

	private func commitPreference(_ body: SyncedRecordBody) async throws(PreferenceWriteFailure) {
		_ = await loadedPreferences()
		let stamp = OperationStamp(
			operation: .preferenceChange(PreferenceChangeID(ulid: await ledger.nextULID())),
			attempt: AttemptID(ulid: await ledger.nextULID()),
			binding: binding
		)
		let committed: [AthleteRecord]
		do {
			committed = try await ledger.commit(synced: [body], stamp: stamp)
		} catch {
			throw .notSaved
		}
		preferenceRecords += committed
		await publishStatus()
	}

	func loadedPreferences() async -> Preferences {
		guard !preferencesLoaded else { return Preferences.fold(preferenceRecords) }
		let reading = preferencesRead ?? Task { await self.readPreferences() }
		preferencesRead = reading
		let result = await reading.value
		if preferencesRead == reading {
			preferencesRead = nil
		}
		switch result {
		case .success(let stored) where !preferencesLoaded:
			preferenceRecords =
				stored
				+ preferenceRecords.filter { written in
					!stored.contains { $0.ulid == written.ulid }
				}
			preferencesLoaded = true
		case .success:
			break
		case .failure(let error):
			diagnostics.record(.preferencesUnavailable(error))
		}
		return Preferences.fold(preferenceRecords)
	}

	private func readPreferences() async -> Result<[AthleteRecord], LedgerFailure> {
		do {
			return .success(try await ledger.read(RecordQuery(scope: Preferences.scope)).records)
		} catch {
			return .failure(error)
		}
	}

}
