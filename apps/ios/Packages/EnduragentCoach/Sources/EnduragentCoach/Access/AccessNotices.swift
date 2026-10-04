extension AccessStatus {
	public var notice: AthleteNotice? {
		if attention == .rejectedKey {
			return AthleteNotice(
				key: Catalog.coachErrorReauth, vars: ["provider": "OpenRouter"],
				action: .signInToOpenRouter)
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
			AthleteNotice(key: Catalog.reviewSaveFailed, action: nil)
		case .failedPreviousKept(.signIn(.canceled), _):
			AthleteNotice(key: Catalog.accessSignInCancelled, action: nil)
		case .failedPreviousKept(.signIn, _), .failedPreviousKept(.keyExchange, _), .refused:
			AthleteNotice(key: Catalog.accessSignInIncomplete, action: nil)
		}
	}
}

extension CreditBalance {
	public var notice: AthleteNotice? {
		credits.units <= 0 ? AthleteNotice(key: Catalog.creditsErrorExhausted, action: nil) : nil
	}
}
