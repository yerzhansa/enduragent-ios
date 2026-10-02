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
		case .failedPreviousKept: AthleteNotice(key: Catalog.connectErrorNotSaved, action: nil)
		case .kept, .disconnected, .refused: nil
		}
	}
}
