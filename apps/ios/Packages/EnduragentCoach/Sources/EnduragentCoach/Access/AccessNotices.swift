extension AccessStatus {
	public var notice: AthleteNotice? {
		if attention == .rejectedKey {
			return AthleteNotice(
				key: Catalog.coachErrorReauth, vars: ["provider": "OpenRouter"],
				actions: [.signInToOpenRouter])
		}
		let failure: AccessUnavailable
		switch availability {
		case .ready: return nil
		case .needsSetup: failure = .notConfigured(savedMethod ?? .credits)
		case .unavailable(let unavailable): failure = unavailable
		}
		return AthleteNotices.notice(
			for: .model(.accessUnavailable(failure)), turn: nil, waiting: false)
	}
}

extension CredentialOutcome where Summary == AccessSummary {
	public var notice: AthleteNotice? {
		switch self {
		case .kept, .replaced, .disconnected: nil
		case .failedPreviousKept(.secureStorage, _):
			AthleteNotice(key: Catalog.reviewSaveFailed, actions: [])
		case .failedPreviousKept(.signIn(.canceled), _):
			AthleteNotice(key: Catalog.accessSignInCancelled, actions: [])
		case .failedPreviousKept(.signIn, _), .failedPreviousKept(.keyExchange, _), .refused:
			AthleteNotice(key: Catalog.accessSignInIncomplete, actions: [])
		}
	}
}

extension CreditBalance {
	public var notice: AthleteNotice? {
		credits.units <= 0 ? AthleteNotice(key: Catalog.creditsErrorExhausted, actions: []) : nil
	}
}
