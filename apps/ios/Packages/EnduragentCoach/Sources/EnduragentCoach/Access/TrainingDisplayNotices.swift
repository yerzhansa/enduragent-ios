extension IntervalsSummary {
	public var notice: AthleteNotice? {
		let key: CatalogKey
		switch profile {
		case .waiting: key = Catalog.connectProfileWaiting
		case .failed(.credentialRejected): key = Catalog.connectErrorRejected
		case .failed(.requestRejected):
			return AthleteNotice(
				key: Catalog.coachErrorIntervalsCredentials, vars: ["service": "intervals.icu"],
				action: nil)
		case .failed(.temporarilyUnavailable):
			key = Catalog.connectErrorProfileUnavailable
		case .available(let athlete):
			switch athlete.wellness {
			case .waiting: key = Catalog.connectWellnessWaiting
			case .failed(.requestRejected): key = Catalog.connectErrorWellnessRejected
			case .failed(.temporarilyUnavailable): key = Catalog.connectErrorWellnessUnavailable
			case .available(.noData): key = Catalog.connectWellnessEmpty
			case .available(.day): return nil
			}
		}
		return AthleteNotice(key: key, action: nil)
	}

	public var action: TrainingDisplayAction? {
		switch profile {
		case .failed(.temporarilyUnavailable): .retry(connectionID)
		case .failed(.credentialRejected), .failed(.requestRejected): .reviewConnection
		case .available(let athlete):
			switch athlete.wellness {
			case .failed(.temporarilyUnavailable): .retry(connectionID)
			case .failed(.requestRejected): .reviewConnection
			case .waiting, .available: nil
			}
		case .waiting: nil
		}
	}
}

extension CredentialOutcome where Summary == IntervalsSummary {
	public var saveNotice: AthleteNotice? {
		switch self {
		case .replaced: AthleteNotice(key: Catalog.planViewEndedSaved, action: nil)
		case .refused(.blankReplacementKeepsCurrent):
			AthleteNotice(key: Catalog.connectErrorBlank, action: nil)
		case .refused(.blankConnection):
			AthleteNotice(key: Catalog.connectErrorBlankConnection, action: nil)
		case .failedPreviousKept(_, let previous):
			AthleteNotice(
				key: previous == nil
					? Catalog.connectErrorConnectionNotSaved : Catalog.connectErrorNotSaved,
				action: nil)
		case .kept, .disconnected, .refused: nil
		}
	}
}

extension TrainingStatus {
	public var notice: AthleteNotice? {
		switch self {
		case .unconnected: AthleteNotice(key: Catalog.connectMissing, action: .connectTraining)
		case .connected(let summary, _): summary.notice
		case .unavailable(let failure):
			AthleteNotice(key: failure.trainingNoticeKey, action: nil)
		}
	}

	public var action: TrainingDisplayAction? {
		switch self {
		case .connected(let summary, _): summary.action
		case .unavailable(.secureStorageLocked), .unavailable(.secureStorageUnavailable):
			.retryStorage
		case .unconnected, .unavailable: nil
		}
	}

	public var connectionActionTitle: CatalogKey? {
		switch self {
		case .connected, .unavailable(.malformedStoredCredential): Catalog.settingsTrainingReplace
		case .unavailable(.secureStorageLocked), .unavailable(.secureStorageUnavailable): nil
		case .unconnected, .unavailable: Catalog.onboardingConnectAction
		}
	}
}

extension AccessUnavailable {
	fileprivate var trainingNoticeKey: CatalogKey {
		switch self {
		case .secureStorageLocked: Catalog.connectErrorStorageLocked
		case .secureStorageUnavailable: Catalog.connectErrorStorageUnavailable
		case .malformedStoredCredential: Catalog.connectErrorStorageMalformed
		case .notConfigured: Catalog.connectMissing
		case .providerConsentRequired: Catalog.accessErrorProviderConsentRequired
		case .trainingIdentityUnverified(let failure): AthleteNotices.notice(for: failure).key
		}
	}
}
