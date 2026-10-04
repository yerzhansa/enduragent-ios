package enum AccessState: Equatable, Sendable {
	case defaultCredits(AccessAvailability)
	case credits(AccessAvailability)
	case openRouter(OpenRouterChoice)
	case rejectedOpenRouter(OpenRouterChoice)
	case unresolvedOpenRouter(SavedOpenRouterReference, AccessUnavailable)
	case unreadable(AccessUnavailable)
}

public enum AccessAttention: Equatable, Sendable {
	case signInNeeded
	case rejectedKey
}

public enum AccessAvailability: Equatable, Sendable {
	case ready
	case needsSetup
	case unavailable(AccessUnavailable)
}

public struct AccessStatus: Equatable, Sendable {
	private let state: AccessState
	private let builtInModel: ModelID
	private let catalog: ModelCatalogStatus
	public let consent: AccessConsent

	public var modelChoices: OpenRouterModelChoices? {
		let choice: OpenRouterChoice
		switch state {
		case .openRouter(let selected), .rejectedOpenRouter(let selected): choice = selected
		default: return nil
		}
		return OpenRouterModelChoices(selected: choice.entry, catalog: catalog)
	}

	public var selection: AccessSelection? {
		switch state {
		case .defaultCredits(.ready), .credits(.ready): .credits
		case .openRouter(let choice), .rejectedOpenRouter(let choice): .openRouterAccount(choice)
		case .defaultCredits, .credits, .unresolvedOpenRouter, .unreadable: nil
		}
	}

	public var savedMethod: AccessMethod? {
		switch state {
		case .defaultCredits, .unreadable: nil
		case .credits: .credits
		case .openRouter, .rejectedOpenRouter, .unresolvedOpenRouter: .openRouterAccount
		}
	}

	public var model: ModelID? {
		switch state {
		case .defaultCredits, .credits: builtInModel
		case .openRouter(let choice), .rejectedOpenRouter(let choice): choice.model
		case .unresolvedOpenRouter(let reference, _): reference.model
		case .unreadable: nil
		}
	}

	public var attention: AccessAttention? {
		switch state {
		case .rejectedOpenRouter: .rejectedKey
		case .unresolvedOpenRouter(_, .notConfigured): .signInNeeded
		default: nil
		}
	}

	public var availability: AccessAvailability {
		switch state {
		case .defaultCredits(let availability), .credits(let availability): availability
		case .openRouter: .ready
		case .rejectedOpenRouter: .unavailable(.openRouterKeyRejected)
		case .unresolvedOpenRouter(_, .notConfigured): .needsSetup
		case .unresolvedOpenRouter(_, let failure), .unreadable(let failure): .unavailable(failure)
		}
	}

	package init(
		state: AccessState, builtInModel: ModelID, catalog: ModelCatalog = .bundled,
		consent: AccessConsent = .unavailable
	) {
		self.consent = consent
		self.state = state
		self.builtInModel = builtInModel
		self.catalog = ModelCatalogStatus(catalog: catalog, cache: .available(.bundled))
	}
}
