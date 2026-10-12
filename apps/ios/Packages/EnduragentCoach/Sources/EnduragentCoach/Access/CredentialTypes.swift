import Foundation

public enum AccessSelection: Hashable, Sendable {
	case credits
	case openRouterAccount(OpenRouterChoice)

	public var method: AccessMethod {
		switch self {
		case .credits: .credits
		case .openRouterAccount: .openRouterAccount
		}
	}
}

public struct OpenRouterChoice: Hashable, Sendable {
	public var model: ModelID { entry.id }
	package let credential: OpenRouterCredentialRef
	package let entry: ModelCatalogEntry

	package init(credential: Persisted<OpenRouterAccountKey>, entry: ModelCatalogEntry) {
		self.credential = credential.value.reference
		self.entry = entry
	}
}

public enum OpenRouterCredentialRef: Hashable, Sendable {
	case legacy
	case generation(UUID)

	package var account: String {
		switch self {
		case .legacy: CredentialSlot.openRouterAccountKey.rawValue
		case .generation(let id): "openRouterAccountKey/\(id.uuidString)"
		}
	}
}

package struct OpenRouterAccountKey: Equatable, Sendable {
	let reference: OpenRouterCredentialRef
	let secret: NonEmptySecret
}

package struct CreditsKey: Equatable, Sendable {
	let secret: NonEmptySecret
}

package struct SavedOpenRouterReference: Equatable, Sendable {
	let credential: OpenRouterCredentialRef
	let model: ModelID
	let details: ModelDetails?

	package init(credential: OpenRouterCredentialRef, model: ModelID, details: ModelDetails? = nil)
	{
		self.credential = credential
		self.model = model
		self.details = details
	}
}

public struct SavedAccessReference: Equatable, Sendable {
	package enum Value: Equatable, Sendable {
		case credits
		case openRouter(SavedOpenRouterReference)
	}

	package let value: Value
	package let consentCommit: UUID?

	package init(_ value: Value, consentCommit: UUID? = nil) {
		self.value = value
		self.consentCommit = consentCommit
	}
}

public enum CredentialSlot: String, Hashable, Sendable {
	case creditsAccount
	case openRouterAccountKey
	case intervalsConnection = "intervalsCredential"
	case accessSelection
}

public struct CreditsAccount: Codable, Equatable, Sendable {
	public var appAccountToken: UUID
	public var key: String?

	public init(appAccountToken: UUID, key: String?) {
		self.appAccountToken = appAccountToken
		self.key = key
	}
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
	public let id: ConnectionID
	public let credential: IntervalsCredential
	public let selection: AthleteSelection
	public let resolvedAthlete: IntervalsAthleteID?

	public init(
		id: ConnectionID,
		credential: IntervalsCredential,
		selection: AthleteSelection,
		resolvedAthlete: IntervalsAthleteID?
	) {
		self.id = id
		self.credential = credential
		self.selection = selection
		self.resolvedAthlete = resolvedAthlete
	}

	func matches(_ other: IntervalsConnection) -> Bool {
		id == other.id && credential == other.credential && selection == other.selection
	}

	var account: TrainingAccount {
		.intervals(connection: id, athlete: resolvedAthlete)
	}

	func account(verifiedBy profile: IntervalsProfileState) -> TrainingAccount {
		guard case .available(let athlete) = profile else {
			return .intervals(connection: id, athlete: nil)
		}
		return .intervals(connection: id, athlete: athlete.athleteID)
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
	case signInToOpenRouter
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
	case blankConnection
	case blankReplacementKeepsCurrent
	case differentAthlete(current: IntervalsAthleteID, new: IntervalsAthleteID)
	case modelNotInCatalog
}

public enum CredentialFailure: Error, Sendable, Equatable {
	case secureStorage(AccessUnavailable)
	case signIn(SignInFailure)
	case keyExchange(OpenRouterExchangeFailure)
}

public enum SignInFailure: Error, Sendable, Equatable {
	case canceled
	case callbackRejected
	case presentationUnavailable
}

public enum OpenRouterExchangeFailure: Error, Sendable, Equatable {
	case network
	case http(status: Int)
	case invalidResponse
}

public struct AccessSummary: Sendable, Equatable {
	public let selection: AccessSelection
}

public struct CreditsIdentity: Sendable, Equatable {
	public let appAccountToken: UUID?
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

public struct ModelID: Hashable, Sendable {
	public let rawValue: String

	public init(rawValue: String) {
		self.rawValue = rawValue
	}
}

public enum AccessMethod: String, Codable, Hashable, Sendable {
	case credits
	case openRouterAccount
}
