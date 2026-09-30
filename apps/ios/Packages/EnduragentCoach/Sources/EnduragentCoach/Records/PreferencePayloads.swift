import Foundation

struct ProviderConsentPayload: Codable {
	var version: Int
	var at: Double

	init(_ consent: ProviderConsent) {
		self.version = consent.version
		self.at = consent.at.timeIntervalSinceReferenceDate
	}

	func body() -> ProviderConsent {
		ProviderConsent(version: version, at: Date(timeIntervalSinceReferenceDate: at))
	}
}

struct SessionSettingsPayload: Codable {
	var historyBudgetRatio: Double
	var contextWindowTokens: Int?
	var compactionModel: String
	var flushModel: String

	init(_ body: SessionSettingsBody) {
		let settings = body.settings
		self.historyBudgetRatio = settings.historyBudgetRatio.value
		self.contextWindowTokens = settings.contextWindowOverride?.tokens
		self.compactionModel = settings.compactionModel.text
		self.flushModel = settings.flushModel.text
	}

	func body() throws(SessionSettingRejected) -> SessionSettingsBody {
		SessionSettingsBody(
			settings: SessionSettings(
				historyBudgetRatio: try HistoryBudgetRatio(historyBudgetRatio),
				contextWindowOverride: try contextWindowTokens.map {
					(tokens: Int) throws(SessionSettingRejected) in
					try ContextWindowOverride(tokens: tokens)
				},
				compactionModel: try ModelSelection(text: compactionModel, field: .compactionModel),
				flushModel: try ModelSelection(text: flushModel, field: .flushModel)
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
