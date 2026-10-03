package enum AccessState: Equatable, Sendable {
	case defaultCredits(AccessAvailability)
	case credits(AccessAvailability)
	case openRouter(OpenRouterChoice)
	case unresolvedOpenRouter(SavedOpenRouterReference, AccessUnavailable)
	case unreadable(AccessUnavailable)
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

	public var modelChoices: OpenRouterModelChoices? {
		guard case .openRouter(let choice) = state else { return nil }
		return OpenRouterModelChoices(selected: choice.entry, catalog: catalog)
	}

	public var selection: AccessSelection? {
		switch state {
		case .defaultCredits(.ready), .credits(.ready): .credits
		case .openRouter(let choice): .openRouterAccount(choice)
		case .defaultCredits, .credits, .unresolvedOpenRouter, .unreadable: nil
		}
	}

	public var savedMethod: AccessMethod? {
		switch state {
		case .defaultCredits, .unreadable: nil
		case .credits: .credits
		case .openRouter, .unresolvedOpenRouter: .openRouterAccount
		}
	}

	public var model: ModelID? {
		switch state {
		case .defaultCredits, .credits: builtInModel
		case .openRouter(let choice): choice.model
		case .unresolvedOpenRouter(let reference, _): reference.model
		case .unreadable: nil
		}
	}

	public var availability: AccessAvailability {
		switch state {
		case .defaultCredits(let availability), .credits(let availability): availability
		case .openRouter: .ready
		case .unresolvedOpenRouter(_, .notConfigured): .needsSetup
		case .unresolvedOpenRouter(_, let failure), .unreadable(let failure): .unavailable(failure)
		}
	}

	package init(state: AccessState, builtInModel: ModelID, catalog: ModelCatalog = .bundled) {
		self.state = state
		self.builtInModel = builtInModel
		self.catalog = ModelCatalogStatus(catalog: catalog, cache: .available(.bundled))
	}
}
