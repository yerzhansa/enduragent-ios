import Foundation

struct ProviderConsentPayload: Codable {
	var version: Int
	var at: Double
	var method: AccessMethod?
	var model: String?
	var details: StoredModelDetails?
	var selectionCommit: UUID?

	init(_ consent: ProviderConsent) {
		self.version = consent.version
		self.at = consent.at.timeIntervalSinceReferenceDate
		self.method = consent.target?.method
		self.model = consent.target?.entry.id.rawValue
		self.details = consent.target.map { StoredModelDetails($0.entry.details) }
		self.selectionCommit = consent.selectionCommit
	}

	func body() throws -> ProviderConsent {
		let date = Date(timeIntervalSinceReferenceDate: at)
		if version == 1 { return ProviderConsent(legacyAt: date) }
		guard let method, let model, let details else {
			throw RecordDecodeFailure(reason: "providerConsent")
		}
		return ProviderConsent(
			target: ConsentTarget(
				method: method,
				entry: try ModelCatalogEntry(
					id: ModelID(rawValue: model), details: details.validated())),
			at: date, version: version, selectionCommit: selectionCommit)
	}
}

struct SessionSettingsPayload: Codable {
	var historyBudgetRatio: Double
	var contextWindowTokens: Int?

	init(_ body: SessionSettingsBody) {
		let settings = body.settings
		self.historyBudgetRatio = settings.historyBudgetRatio.value
		self.contextWindowTokens = settings.contextWindowOverride?.tokens
	}

	func body() throws(SessionSettingRejected) -> SessionSettingsBody {
		SessionSettingsBody(
			settings: SessionSettings(
				historyBudgetRatio: try HistoryBudgetRatio(historyBudgetRatio),
				contextWindowOverride: try contextWindowTokens.map {
					(tokens: Int) throws(SessionSettingRejected) in
					try ContextWindowOverride(tokens: tokens)
				}
			))
	}
}

struct LanguagePreferencePayload: Codable {
	var tag: String?

	init(_ body: LanguagePreferenceBody) {
		switch body.preference {
		case .automatic: tag = nil
		case .fixed(let fixed): tag = fixed.rawValue
		}
	}

	func body() throws -> LanguagePreferenceBody {
		guard let tag else { return LanguagePreferenceBody(preference: .automatic) }
		guard let fixed = LanguageTag(rawValue: tag) else {
			throw RecordDecodeFailure(reason: "languagePreference")
		}
		return LanguagePreferenceBody(preference: .fixed(fixed))
	}
}
