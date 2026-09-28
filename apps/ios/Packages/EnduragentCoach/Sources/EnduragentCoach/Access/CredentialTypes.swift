import Foundation

public enum AccessSelection: Hashable, Sendable {
	case credits
	case openRouterAccount(model: ModelID, consent: ProviderConsent)

	public var method: AccessMethod {
		switch self {
		case .credits: .credits
		case .openRouterAccount: .openRouterAccount
		}
	}
}

public struct ProviderConsent: Hashable, Sendable {
	public let provider: String
	public let model: ModelID
	public let at: Date

	public init(provider: String, model: ModelID, at: Date) {
		self.provider = provider
		self.model = model
		self.at = at
	}
}

public enum CredentialSlot: String, Hashable, Sendable {
	case appAccountToken
	case creditsKey = "openRouterKey"
	case openRouterAccountKey
	case intervalsConnection = "intervalsCredential"
	case intervalsConnectionStaging
	case accessSelection
}

public enum CredentialReplacement: Sendable, Equatable {
	case intervals(IntervalsConnection)
	case credits(previousKey: String?, previousAppAccountToken: UUID)
}

public enum IntervalsCredential: Sendable, Equatable {
	case apiKey(String)
	case oauth(access: String, refresh: String)

	var keySuffix: String {
		switch self {
		case .apiKey(let key): String(key.suffix(4))
		case .oauth(let access, _): String(access.suffix(4))
		}
	}
}

public struct IntervalsConnection: Sendable, Equatable {
	public let id: ConnectionID?
	public let credential: IntervalsCredential
	public let selection: AthleteSelection
	public let resolvedAthlete: IntervalsAthleteID?

	public init(
		id: ConnectionID?,
		credential: IntervalsCredential,
		selection: AthleteSelection,
		resolvedAthlete: IntervalsAthleteID?
	) {
		self.id = id
		self.credential = credential
		self.selection = selection
		self.resolvedAthlete = resolvedAthlete
	}
}

public enum AthleteSelection: Sendable, Equatable {
	case keyOwner
	case athlete(IntervalsAthleteID)
}

public enum IntervalsConnectionChange: Sendable, Equatable {
	case keep
	case replace(apiKey: String, athlete: AthleteSelection)
	case replaceConfirmingAthleteSwitch(apiKey: String, athlete: AthleteSelection)
	case disconnect
}

public enum ModelAccessChange: Sendable, Equatable {
	case keep
	case useCredits
	case signInToOpenRouter(model: ModelID, consent: ProviderConsent)
	case selectOpenRouterModel(ModelID)
	case disconnectOpenRouter
}

public enum CredentialOutcome<Summary: Sendable & Equatable>: Sendable, Equatable {
	case kept(Summary?)
	case replaced(Summary, authority: AccountAuthority?)
	case disconnected
	case refused(CredentialRefusal)
	case failedPreviousKept(CredentialFailure, previous: Summary?)
}

public enum CredentialRefusal: Sendable, Equatable {
	case blankReplacementKeepsCurrent
	case differentAthlete(current: IntervalsAthleteID, new: IntervalsAthleteID)
	case modelNotInCatalog
}

public enum CredentialFailure: Error, Sendable, Equatable {
	case secureStorage(AccessUnavailable)
	case signIn(SignInFailure)
}

public enum SignInFailure: Error, Sendable, Equatable {
	case presentationUnavailable
}

public struct IntervalsSummary: Sendable, Equatable {
	public let keySuffix: String
	public let athleteName: String?
	public let today: WellnessDay?
	public let displayUnavailable: TrainingFailure?
}

public struct AccessSummary: Sendable, Equatable {
	public let selection: AccessSelection
}

public struct CreditsIdentity: Sendable, Equatable {
	public let appAccountToken: UUID
	public let hasCreditsKey: Bool
}

package struct NonEmptySecret: Sendable, Equatable {
	package let value: String

	package init?(_ raw: String) {
		let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmed.isEmpty else { return nil }
		self.value = trimmed
	}
}
